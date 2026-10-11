defmodule Jantar.History do
  @moduledoc """
  Owns every time series and every sensor's latest reading, in ETS.

  Two tables, both `:protected` (only this process writes, anyone reads) with
  `read_concurrency`, so a renderer or `mix jantar.dump` reads without sending a
  message:

    * `:jantar_samples` (`ordered_set`): one row per sample,
      `{{series, seq}, t_ms, value}`. Because it is ordered by key, all the
      samples of one series sit together in seq (= time) order, and reading
      one series walks just that range. A push inserts one small row instead
      of rewriting a whole ring.

    * `:jantar_state` (`set`): `{{:ring, series}, ring}` with the
      Gleam window bookkeeping for each series, and
      `{{:sensor, name}, status, current, t_ms}` with each sensor's status and
      latest values.

  Which samples to drop (outside the series' time window, or over the point
  cap) is decided by the Gleam `jantar_core/ring` module; this process just
  applies it to the table.

  `t_ms` is monotonic time in milliseconds (`System.monotonic_time/1`).
  Values are numbers, or `nil` for "no reading" (a gap).

  With `config :jantar, state_dir:` set (the NixOS service sets it to its
  StateDirectory), the samples are saved to `history.etf` there on shutdown
  and loaded on start, so a restart or a rebuild doesn't empty the dials. It
  writes only then, not as it goes. Monotonic time restarts with the VM, so
  timestamps are saved as wall-clock time and converted back on load; the
  time it was down shows as a gap, and samples past their window fall out
  on the next push as usual.
  """
  use GenServer
  require Logger

  @samples :jantar_samples
  @state :jantar_state

  # Series nobody declared get this window.
  @default_window_ms 30 * 60_000

  # ------------------------------------------------------------------ writing

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Declare a series with its time window (and optionally a point cap). An
  existing series keeps its samples; only its limits change.
  """
  def declare(series, window_ms, max_points \\ nil) do
    GenServer.call(__MODULE__, {:declare, series, window_ms, max_points})
  end

  @doc """
  Append a sample. A call rather than a cast: writes stay ordered with reads
  that follow, and at a few pushes per second the round trip costs nothing.
  """
  def push(series, t_ms, value) do
    GenServer.call(__MODULE__, {:push, series, t_ms, value})
  end

  @doc "Record a sensor's status (`:ok` or `{:unavailable, reason}`) and latest values."
  def put_sensor(name, status, current, t_ms) do
    GenServer.call(__MODULE__, {:put_sensor, name, status, current, t_ms})
  end

  # ------------------------------------------------------------------ reading (any process)

  @doc "A series' samples as `{t_ms, value}`, oldest first."
  def samples(series) do
    :ets.select(@samples, [{{{series, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc "A series' newest sample `{t_ms, value}`, or nil."
  def last(series) do
    with %{ring: ring} <- info(series),
         [{_key, t, v}] <- :ets.lookup(@samples, {series, :jantar_core@ring.total(ring) - 1}) do
      {t, v}
    else
      _ -> nil
    end
  end

  @doc """
  A series' bookkeeping: `%{size:, total:, window_ms:, max_points:, ring:}`,
  or nil if undeclared. `total` counts every sample ever pushed.
  """
  def info(series) do
    case :ets.lookup(@state, {:ring, series}) do
      [{_, ring}] ->
        {:ring, window_ms, max_points, _first, next} = ring

        %{
          size: :jantar_core@ring.size(ring),
          total: next,
          window_ms: window_ms,
          max_points: max_points,
          ring: ring
        }

      [] ->
        nil
    end
  end

  @doc "Every declared series name, sorted."
  def series do
    :ets.match(@state, {{:ring, :"$1"}, :_}) |> Enum.map(&hd/1) |> Enum.sort()
  end

  @doc "A sensor's `%{status:, current:, t_ms:}`, or nil if it never reported."
  def sensor(name) do
    case :ets.lookup(@state, {:sensor, name}) do
      [{_, status, current, t}] -> %{status: status, current: current, t_ms: t}
      [] -> nil
    end
  end

  @doc "The current values of a sensor (a map), or nil."
  def current(name) do
    case sensor(name) do
      %{current: current} -> current
      nil -> nil
    end
  end

  # ------------------------------------------------------------------ server

  @impl true
  def init(opts) do
    # So terminate/2 runs on shutdown, to save.
    Process.flag(:trap_exit, true)
    :ets.new(@samples, [:ordered_set, :protected, :named_table, read_concurrency: true])
    :ets.new(@state, [:set, :protected, :named_table, read_concurrency: true])
    file = save_file(Keyword.get(opts, :state_dir, Application.get_env(:jantar, :state_dir)))
    if file, do: load(file)
    {:ok, %{max_points: Application.get_env(:jantar, :max_points, 7200), file: file}}
  end

  @impl true
  def terminate(_reason, %{file: file}) when is_binary(file), do: save(file)
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:declare, series, window_ms, max_points}, _from, state) do
    cap = min(max_points || state.max_points, state.max_points)

    ring =
      case :ets.lookup(@state, {:ring, series}) do
        # Keep the samples and sequence numbers; change only the limits.
        [{_, {:ring, _, _, first, next}}] -> {:ring, window_ms, max(2, cap), first, next}
        [] -> :jantar_core@ring.new(window_ms, cap)
      end

    :ets.insert(@state, {{:ring, series}, ring})
    {:reply, :ok, state}
  end

  def handle_call({:push, series, t, value}, _from, state) do
    ring =
      case :ets.lookup(@state, {:ring, series}) do
        [{_, ring}] -> ring
        [] -> :jantar_core@ring.new(@default_window_ms, state.max_points)
      end

    {ring, seq} = :jantar_core@ring.push(ring)
    :ets.insert(@samples, {{series, seq}, t, value})

    # Gleam decides which samples fall out; it asks for timestamps as needed.
    time_of = fn seq ->
      case :ets.lookup(@samples, {series, seq}) do
        [{_, t, _}] -> {:ok, t}
        [] -> {:error, nil}
      end
    end

    {ring, dropped} = :jantar_core@ring.trim(ring, t, time_of)
    Enum.each(dropped, fn seq -> :ets.delete(@samples, {series, seq}) end)
    :ets.insert(@state, {{:ring, series}, ring})
    {:reply, :ok, state}
  end

  def handle_call({:put_sensor, name, status, current, t}, _from, state) do
    :ets.insert(@state, {{:sensor, name}, status, current, t})
    {:reply, :ok, state}
  end

  # ------------------------------------------------------------------ saving

  @version 1

  defp save_file(nil), do: nil
  defp save_file(dir), do: Path.join(dir, "history.etf")

  # Monotonic -> wall clock offset, to save timestamps that survive a restart.
  defp wall_offset, do: System.system_time(:millisecond) - System.monotonic_time(:millisecond)

  @doc false
  def save(file) do
    offset = wall_offset()
    rings = :ets.match_object(@state, {{:ring, :_}, :_})
    samples = for {key, t, v} <- :ets.tab2list(@samples), do: {key, t + offset, v}
    data = :erlang.term_to_binary({@version, rings, samples}, [:compressed])
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, file) do
      Logger.info("history: saved #{length(samples)} samples to #{file}")
    else
      {:error, reason} -> Logger.warning("history: couldn't save #{file}: #{inspect(reason)}")
    end
  end

  defp load(file) do
    with {:ok, data} <- File.read(file),
         {@version, rings, samples} <- :erlang.binary_to_term(data, [:safe]) do
      offset = wall_offset()
      :ets.insert(@state, rings)
      :ets.insert(@samples, for({key, wall, v} <- samples, do: {key, wall - offset, v}))
      Logger.info("history: loaded #{length(samples)} samples from #{file}")
    else
      {:error, :enoent} -> :ok
      other -> Logger.warning("history: ignoring #{file}: #{inspect(other, limit: 5)}")
    end
  rescue
    e -> Logger.warning("history: ignoring #{file}: #{Exception.message(e)}")
  end
end
