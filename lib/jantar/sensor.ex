defmodule Jantar.Sensor do
  @moduledoc """
  One process per data source. This module is both:

    * a **behaviour**: what a source module (`Jantar.Sensors.Cpu`, ...)
      implements: how to find its source, and how to take one sample; and
    * the **GenServer** that runs any such module: scheduling, pushing
      samples into `Jantar.History`, and handling sources that are missing
      or fail.

  The split is the same one OTP itself uses (`GenServer` runs your callbacks):
  source modules hold no process logic and can be tested by calling
  `init/1` and `sample/2` directly.

  ## Lifecycle

      start ──► discover ──ok──► tick ──► tick ──► ...   (every interval)
                   │                │
                   │ unavailable    │ unavailable / raised
                   ▼                ▼
                 wait (backoff 5 s, 10 s, ... 5 min) ──► discover again

  A missing source never crashes the process, so there is no restart loop:
  the sensor reports `{:unavailable, reason}` and retries with backoff.

  ## Options

  Each source's `defaults/0`, then the app config for that module
  (`config :jantar, Jantar.Sensors.Cpu, interval: 500`), then options given
  at start, in increasing priority:

    * `:interval` - ms between samples
    * `:adaptive` - adjust the interval to how fast the value moves
      (default: the global `config :jantar, adaptive:`)
    * `:max_interval` - adaptive upper bound (default 8 x interval)
    * `:noise` - adaptive: changes smaller than this count as flat
    * `:root` - filesystem root (default: `config :jantar, root:`)
    * `:name` - registered name (default: the source module)
    * `:report_as` - name in History (default: from the module, `:ci_runner`)
    * `:first_backoff` - ms before the first retry of a missing source (5000)
  """
  use GenServer
  require Logger

  alias Jantar.{History, Mode}

  @typedoc "A series name: an atom such as `:cpu`, or a tuple such as `{:gpu, \"gt0-rc\"}`."
  @type series :: atom | tuple
  @type reading :: {series, number | nil}

  @doc "Default options for this source (at least `:interval`)."
  @callback defaults() :: keyword

  @doc """
  Find the source. Returns the initial state and the series this source
  feeds, each with its history window in ms.
  """
  @callback init(opts :: keyword) ::
              {:ok, state :: term, [{series, window_ms :: pos_integer}]}
              | {:unavailable, reason :: term}

  @doc """
  Take one sample at monotonic time `now_ms`. `readings` go into History at
  `now_ms`; `current` is a map of the latest values for display.
  """
  @callback sample(state :: term, now_ms :: integer) ::
              {:ok, [reading], current :: map, state :: term}
              | {:unavailable, reason :: term, state :: term}

  @doc "Optional: the interval to use next, given the configured one (e.g. the NPU sleeping)."
  @callback next_interval(state :: term, interval_ms :: pos_integer) :: pos_integer
  @optional_callbacks next_interval: 2

  @first_backoff_ms 5_000
  @max_backoff_ms 300_000
  # Values kept for the adaptive policy.
  @adaptive_window 8

  # ------------------------------------------------------------------ API

  def start_link(opts) do
    module = Keyword.fetch!(opts, :module)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, module))
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, Keyword.fetch!(opts, :module)),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "The short name a source reports under: `Jantar.Sensors.CiRunner` -> `:ci_runner`."
  def name_of(module) do
    module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
  end

  @doc "The interval the sensor is using now, in ms (for tests and `jantar.dump`)."
  def interval(server), do: GenServer.call(server, :interval)

  @doc "The full options a source module would run with (defaults, then config, then `overrides`)."
  def options(module, overrides \\ []) do
    [
      root: Application.get_env(:jantar, :root, "/"),
      adaptive: Application.get_env(:jantar, :adaptive, false)
    ]
    |> Keyword.merge(module.defaults())
    |> Keyword.merge(Application.get_env(:jantar, module, []))
    |> Keyword.merge(overrides)
  end

  # ------------------------------------------------------------------ server

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    opts = options(module, Keyword.delete(opts, :module))

    state = %{
      module: module,
      name: Keyword.get(opts, :report_as, name_of(module)),
      opts: opts,
      source: nil,
      status: :starting,
      interval: opts[:interval],
      due: nil,
      failures: 0,
      recent: []
    }

    {:ok, state, {:continue, :discover}}
  end

  @impl true
  def handle_continue(:discover, state), do: discover(state)

  @impl true
  def handle_info(:discover, state), do: discover(state)

  def handle_info(:tick, state) do
    now = now_ms()

    case safe_sample(state, now) do
      {:ok, readings, current, source} ->
        for {series, value} <- readings, do: History.push(series, now, value)
        History.put_sensor(state.name, :ok, current, now)

        %{state | source: source, status: :ok, failures: 0}
        |> adapt(readings)
        |> schedule_tick(now)

      {:unavailable, reason, source} ->
        unavailable(%{state | source: source}, reason, now)
    end
  end

  @impl true
  def handle_call(:interval, _from, state), do: {:reply, state.interval, state}

  # ------------------------------------------------------------------ internals

  defp discover(state) do
    now = now_ms()

    case safe_init(state) do
      {:ok, source, series} ->
        for {name, window_ms} <- series, do: History.declare(name, window_ms)
        if state.status != :starting, do: Logger.info("#{state.name}: source available again")
        # First sample straight away.
        send(self(), :tick)
        {:noreply, %{state | source: source, status: :ok, failures: 0, due: now}}

      {:unavailable, reason} ->
        unavailable(state, reason, now)
    end
  end

  # Report, then try discovery again later, waiting longer each time.
  defp unavailable(state, reason, now) do
    if state.status != {:unavailable, reason} do
      Logger.info("#{state.name}: unavailable (#{inspect(reason)}); retrying with backoff")
    end

    History.put_sensor(state.name, {:unavailable, reason}, nil, now)
    first = state.opts[:first_backoff] || @first_backoff_ms
    backoff = min(first * Integer.pow(2, state.failures), @max_backoff_ms)
    Process.send_after(self(), :discover, backoff)
    {:noreply, %{state | status: {:unavailable, reason}, failures: state.failures + 1}}
  end

  # A source module that raises is treated as unavailable, not crashed: a bug
  # or an odd file shouldn't turn into a supervisor restart loop.
  defp safe_init(state) do
    state.module.init(state.opts)
  rescue
    e -> {:unavailable, {:raised, Exception.message(e)}}
  end

  defp safe_sample(state, now) do
    state.module.sample(state.source, now)
  rescue
    e ->
      Logger.warning(
        "#{state.name}: sample raised: " <> Exception.format(:error, e, __STACKTRACE__)
      )

      {:unavailable, {:raised, Exception.message(e)}, state.source}
  end

  # The base interval: configured, or what the source asks for right now.
  defp base_interval(state) do
    if function_exported?(state.module, :next_interval, 2) do
      state.module.next_interval(state.source, state.opts[:interval])
    else
      state.opts[:interval]
    end
  end

  # Without adaptive sampling the interval is just the base. With it, the
  # Gleam policy moves it between the base and max_interval according to how
  # much the first numeric reading has been changing.
  defp adapt(state, readings) do
    base = base_interval(state)

    if state.opts[:adaptive] do
      value = Enum.find_value(readings, fn {_series, v} -> if is_number(v), do: v / 1 end)

      recent =
        if value, do: Enum.take(state.recent ++ [value], -@adaptive_window), else: state.recent

      max_ms = state.opts[:max_interval] || base * 8
      policy = Jantar.Core.policy(base, max(base, max_ms), state.opts[:noise] || 0.0)
      current = max(state.interval || base, base)
      %{state | recent: recent, interval: :jantar_core@adapt.next_interval(recent, current, policy)}
    else
      %{state | interval: base}
    end
  end

  # Ticks are scheduled against a deadline, so the time spent sampling doesn't
  # make the interval drift. After a stall (e.g. suspend) we don't burst to
  # catch up: the next tick is one interval from now.
  defp schedule_tick(state, now) do
    interval = round(state.interval * Mode.interval_factor())
    due = (state.due || now) + interval
    due = if due <= now, do: now + interval, else: due
    Process.send_after(self(), :tick, due, abs: true)
    {:noreply, %{state | due: due}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
