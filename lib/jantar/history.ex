defmodule Jantar.History do
  @moduledoc """
  Owns every time series and every sensor's latest reading, in ETS.

  Three tables, all `:protected` (only this process writes, anyone reads) with
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

    * `:jantar_archive` (`ordered_set`): the same series consolidated at
      coarser steps, RRDtool-style: `{{series, scale, start}, min, mean, max,
      count}`, one row per minute for a day (`:day`) and per hour for 30 days
      (`:month`). Starts are wall-clock ms aligned to the step, so archives
      line up across restarts. The step being filled is kept in
      `:jantar_state` as `{{:open, series, scale}, step}`, so readers see the
      current minute too. The arithmetic is the Gleam `jantar_core/archive`.

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
  @archive :jantar_archive

  # Archive scales: {:spec, step_ms, keep_ms} (a Gleam archive.Spec).
  @scales [day: {:spec, 60_000, 86_400_000}, month: {:spec, 3_600_000, 2_592_000_000}]

  @doc "The archive scales and their `{:spec, step_ms, keep_ms}`."
  def scales, do: @scales

  # Restart marks (`{:event, :restart}`: -10/10 down and up around a reboot,
  # -11/11 around a service restart) are kept this long.
  @restart_window_ms 30 * 86_400_000

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

  @doc """
  A series' archive at `scale` (`:day` or `:month`) as `{start, min, mean,
  max}` rows, oldest first, ending with the step still being filled.
  `start` is wall-clock ms.
  """
  def archive(series, scale) do
    rows =
      :ets.select(@archive, [
        {{{series, scale, :"$1"}, :"$2", :"$3", :"$4", :_}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}
      ])

    case :ets.lookup(@state, {:open, series, scale}) do
      [{_, step}] ->
        {:row, start, min, mean, max, _count} = :jantar_core@archive.finish(step)
        rows ++ [{start, min, mean, max}]

      [] ->
        rows
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
    :ets.new(@archive, [:ordered_set, :protected, :named_table, read_concurrency: true])
    file = save_file(Keyword.get(opts, :state_dir, Application.get_env(:jantar, :state_dir)))

    :ets.insert(
      @state,
      {{:ring, {:event, :restart}}, :jantar_core@ring.new(@restart_window_ms, 1000)}
    )

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
    do_push(series, t, value, state)
    {:reply, :ok, state}
  end

  def handle_call({:put_sensor, name, status, current, t}, _from, state) do
    :ets.insert(@state, {{:sensor, name}, status, current, t})
    {:reply, :ok, state}
  end

  # Mark the time it was down: where the saved history ends, and now.
  @impl true
  def handle_info({:restart_marks, down_t, up_t, kind}, state) do
    code = if kind == :reboot, do: 10, else: 11
    do_push({:event, :restart}, down_t, -code, state)
    do_push({:event, :restart}, up_t, code, state)
    {:noreply, state}
  end

  defp do_push(series, t, value, state) do
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
    # Events are moments, not levels: nothing to average.
    if is_number(value) and not match?({:event, _}, series),
      do: consolidate(series, t + wall_offset(), value / 1)
  end

  # ------------------------------------------------------------------ archives

  # Fold a sample into each scale's open step; store a finished step as a row
  # and drop rows past the scale's retention (once a step, so once a minute
  # at most).
  defp consolidate(series, wall, value) do
    for {scale, spec} <- @scales do
      key = {:open, series, scale}

      open =
        case :ets.lookup(@state, key) do
          [{_, step}] -> {:some, step}
          [] -> :none
        end

      {finished, {:some, step}} = :jantar_core@archive.add(spec, open, wall, value)
      :ets.insert(@state, {key, step})

      with {:some, {:row, start, min, mean, max, count}} <- finished do
        :ets.insert(@archive, {{series, scale, start}, min, mean, max, count})
        cutoff = :jantar_core@archive.expired_before(spec, wall)

        :ets.select_delete(@archive, [
          {{{series, scale, :"$1"}, :_, :_, :_, :_}, [{:<, :"$1", cutoff}], [true]}
        ])
      end
    end
  end

  # ------------------------------------------------------------------ saving

  # 2 added the archives, 3 when it was saved and the boot it was saved in;
  # older files still load.
  @version 3

  defp save_file(nil), do: nil
  defp save_file(dir), do: Path.join(dir, "history.etf")

  # Monotonic -> wall clock offset, to save timestamps that survive a restart.
  defp wall_offset, do: System.system_time(:millisecond) - System.monotonic_time(:millisecond)

  @doc false
  def save(file) do
    offset = wall_offset()
    rings = :ets.match_object(@state, {{:ring, :_}, :_})
    samples = for {key, t, v} <- :ets.tab2list(@samples), do: {key, t + offset, v}
    opens = :ets.match_object(@state, {{:open, :_, :_}, :_})
    archive = :ets.tab2list(@archive)
    meta = %{saved_wall: System.system_time(:millisecond), boot_id: boot_id()}
    data = :erlang.term_to_binary({@version, rings, samples, archive, opens, meta}, [:compressed])
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
         {version, rings, samples, archive, opens, meta} when version in [1, 2, 3] <-
           upgrade(:erlang.binary_to_term(data, [:safe])) do
      offset = wall_offset()
      :ets.insert(@state, rings)
      :ets.insert(@state, opens)
      :ets.insert(@archive, archive)
      :ets.insert(@samples, for({key, wall, v} <- samples, do: {key, wall - offset, v}))
      Logger.info("history: loaded #{length(samples)} samples from #{file}")

      with %{saved_wall: saved} <- meta do
        kind = if meta[:boot_id] == boot_id(), do: :restart, else: :reboot
        send(self(), {:restart_marks, saved - offset, System.monotonic_time(:millisecond), kind})
      end
    else
      {:error, :enoent} -> :ok
      other -> Logger.warning("history: ignoring #{file}: #{inspect(other, limit: 5)}")
    end
  rescue
    e -> Logger.warning("history: ignoring #{file}: #{Exception.message(e)}")
  end

  defp upgrade({1, rings, samples}), do: {1, rings, samples, [], [], %{}}
  defp upgrade({2, rings, samples, archive, opens}), do: {2, rings, samples, archive, opens, %{}}
  defp upgrade(other), do: other

  # Changes with every boot: tells a reboot from a service restart.
  defp boot_id do
    case :file.read_file("/proc/sys/kernel/random/boot_id", [:raw]) do
      {:ok, id} -> String.trim(id)
      _ -> nil
    end
  end
end
