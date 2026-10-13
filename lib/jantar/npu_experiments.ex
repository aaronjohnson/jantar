defmodule Jantar.NpuExperiments do
  @moduledoc """
  Runs the NPU experiment library (experiments/npu, the `npu-experiment` command) on
  request from the NPU screen, one experiment at a time (requests made while
  one runs wait in a queue), and publishes what it is doing as the
  `:npu_experiments` sensor:

      %{state: :idle | :listing | :running, catalogue: [%{name, title, real_world}],
        experiment: name, label: variant, index: n, count: n, queue: [name],
        results: %{name => %{ok: bool, at: unix s, engines: %{"DPU" => share},
                             variants: [%{label, latency_ms, device_ms, ...}]}},
        error: text or nil}

  Each experiment runs as a Port, so a crash or a hung compile in Python or
  OpenVINO can't reach the VM; it is killed on `stop/0` or after
  #{div(15 * 60_000, 60_000)} minutes. Runs are marked on the NPU dials as
  `{:event, :npu_experiment}`: #{20} at the start, #{21} at the end. The
  experiments time themselves with OpenVINO's profiling, not the Level Zero
  counters, so they don't compete with `Jantar.Sensors.NpuCounters`.

  The catalogue is read once (`npu-experiment list --json`), a little after
  start, not at boot. Results are kept in the state directory, so the last
  run of each experiment survives a restart.

  Options: `:exe` (the npu-experiment command; without it nothing starts),
  `:seconds` (per trial of a variant, default 1; 3 trials each), `:list_delay` (ms), `:state_dir`,
  `:name`.
  """
  @behaviour :gen_statem
  require Logger
  alias Jantar.History

  @event {:event, :npu_experiment}
  @start_mark 20
  @end_mark 21
  @run_limit_ms 15 * 60_000
  @retry_list_ms 5 * 60_000

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts),
    do: :gen_statem.start_link({:local, opts[:name] || __MODULE__}, __MODULE__, opts, [])

  @doc "Run the named experiment, or queue it if one is running (unknown names are ignored)."
  def run(name, server \\ __MODULE__), do: :gen_statem.cast(server, {:run, name})

  @doc "Stop the running experiment and empty the queue."
  def stop(server \\ __MODULE__), do: :gen_statem.cast(server, :stop)

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    History.declare(@event, 30 * 60_000)

    data = %{
      exe: Keyword.fetch!(opts, :exe),
      seconds: opts[:seconds] || 1,
      file: opts[:state_dir] && Path.join(opts[:state_dir], "npu_experiments.etf"),
      catalogue: [],
      results: %{},
      port: nil,
      os_pid: nil,
      buffer: "",
      experiment: nil,
      label: nil,
      index: 0,
      count: 0,
      variants: [],
      queue: [],
      error: nil
    }

    # Results from before the rename (npu_examples.etf) carry over once.
    old = opts[:state_dir] && Path.join(opts[:state_dir], "npu_examples.etf")
    results = with r when r == %{} <- load(data.file), do: load(old)
    data = %{data | results: results}
    publish(:idle, data)
    {:ok, :idle, data, [{{:timeout, :list}, opts[:list_delay] || 20_000, :list}]}
  end

  # ------------------------------------------------------------------ events

  @impl true
  def handle_event({:timeout, :list}, :list, :idle, data) do
    data = open(data, ["list", "--json"])
    publish(:listing, data)
    {:next_state, :listing, data}
  end

  def handle_event({:timeout, :list}, :list, _state, _data), do: {:keep_state_and_data, :postpone}

  def handle_event(:cast, {:run, name}, :idle, data) do
    if Enum.any?(data.catalogue, &(&1.name == name)) do
      History.push(@event, now(), @start_mark)

      data =
        open(
          %{data | experiment: name, label: nil, index: 0, count: 0, variants: [], error: nil},
          [
            name,
            "--json",
            "--seconds",
            to_string(data.seconds)
          ]
        )

      publish(:running, data)
      {:next_state, :running, data, [{:state_timeout, @run_limit_ms, :too_long}]}
    else
      :keep_state_and_data
    end
  end

  # Busy: queue it, once (not the one running, nor one already waiting).
  def handle_event(:cast, {:run, name}, :running, data) do
    if Enum.any?(data.catalogue, &(&1.name == name)) and name != data.experiment and
         name not in data.queue do
      data = %{data | queue: data.queue ++ [name]}
      publish(:running, data)
      {:keep_state, data}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:cast, {:run, _}, _state, _data), do: :keep_state_and_data

  def handle_event(:cast, :stop, :running, data) do
    kill(data)
    {:keep_state, %{data | error: "stopped", queue: []}}
  end

  def handle_event(:cast, :stop, _state, _data), do: :keep_state_and_data

  def handle_event(:state_timeout, :too_long, :running, data) do
    Logger.warning(
      "npu experiment #{data.experiment} ran past #{div(@run_limit_ms, 60_000)} min; killed"
    )

    kill(data)
    {:keep_state, %{data | error: "took too long"}}
  end

  # Output, a line at a time (long lines arrive in pieces).
  def handle_event(:info, {port, {:data, {:noeol, chunk}}}, _state, %{port: port} = data),
    do: {:keep_state, %{data | buffer: data.buffer <> chunk}}

  def handle_event(:info, {port, {:data, {:eol, chunk}}}, state, %{port: port} = data) do
    line = data.buffer <> chunk
    data = line(state, line, %{data | buffer: ""})
    publish(state, data)
    {:keep_state, data}
  end

  def handle_event(:info, {port, {:exit_status, status}}, :listing, %{port: port} = data) do
    data = %{data | port: nil, os_pid: nil}

    if data.catalogue == [] do
      Logger.warning("npu-experiment list failed (exit #{status}); trying again in 5 min")
      data = %{data | error: "no experiments (exit #{status})"}
      publish(:idle, data)
      {:next_state, :idle, data, [{{:timeout, :list}, @retry_list_ms, :list}]}
    else
      publish(:idle, data)
      {:next_state, :idle, data}
    end
  end

  def handle_event(:info, {port, {:exit_status, status}}, :running, %{port: port} = data) do
    History.push(@event, now(), @end_mark)
    ok = status == 0 and data.error == nil
    error = data.error || if(status != 0, do: "exit #{status}")

    data =
      if data.variants == [] do
        %{data | error: error}
      else
        result = %{
          ok: ok,
          at: System.os_time(:second),
          engines: engine_share(data.variants),
          variants: Enum.reverse(data.variants)
        }

        results = Map.put(data.results, data.experiment, result)
        save(data.file, results)
        %{data | results: results, error: error}
      end

    data = %{data | port: nil, os_pid: nil}
    publish(:idle, data)

    case data.queue do
      [] ->
        {:next_state, :idle, data}

      [next | rest] ->
        {:next_state, :idle, %{data | queue: rest}, [{:next_event, :cast, {:run, next}}]}
    end
  end

  def handle_event(:info, {:EXIT, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, data), do: kill(data)

  # ------------------------------------------------------------------ output

  defp line(:listing, line, data) do
    case JSON.decode(line) do
      {:ok, list} when is_list(list) ->
        cat =
          for %{"name" => n, "title" => t} = e <- list,
              do: %{name: n, title: t, real_world: e["real_world"] || ""}

        %{data | catalogue: cat}

      _ ->
        data
    end
  end

  defp line(:running, line, data) do
    case JSON.decode(line) do
      # Steps: each variant once per trial (older output: once each).
      {:ok, %{"event" => "start", "variants" => v} = start} ->
        %{data | count: start["steps"] || length(v)}

      {:ok, %{"event" => "variant", "label" => label}} ->
        %{data | label: label, index: data.index + 1}

      {:ok, %{"event" => "result"} = r} ->
        summary = %{
          label: r["label"],
          latency_ms: r["latency_ms"],
          device_ms: r["device_ms"],
          engines_us: r["engines_us"] || %{},
          tops: r["tops"],
          device_tops: r["device_tops"]
        }

        %{data | variants: [summary | data.variants]}

      _ ->
        # Not ours (a warning from a library): the journal has stderr.
        data
    end
  end

  defp line(_state, _line, data), do: data

  # Engine time over all of an experiment's variants, as shares.
  defp engine_share(variants) do
    totals =
      Enum.reduce(variants, %{}, fn v, acc ->
        Map.merge(acc, v.engines_us, fn _, a, b -> a + b end)
      end)

    sum = totals |> Map.values() |> Enum.sum()
    if sum > 0, do: Map.new(totals, fn {k, v} -> {k, v / sum} end), else: %{}
  end

  # ------------------------------------------------------------------ helpers

  defp open(data, args) do
    port =
      Port.open({:spawn_executable, data.exe}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: args,
        # OpenVINO wants somewhere to write; the service's home is read-only.
        env: [{~c"HOME", ~c"/tmp"}]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    %{data | port: port, os_pid: pid, buffer: ""}
  end

  # Closing a Port doesn't end the program: signal it.
  defp kill(%{os_pid: pid}) when is_integer(pid) do
    System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp kill(_), do: :ok

  defp publish(state, data) do
    current =
      data
      |> Map.take([:catalogue, :results, :experiment, :label, :index, :count, :queue, :error])
      |> Map.put(:state, state)

    History.put_sensor(:npu_experiments, :ok, current, now())
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp load(nil), do: %{}

  defp load(file) do
    case File.read(file) do
      {:ok, bin} -> :erlang.binary_to_term(bin, [:safe])
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save(nil, _), do: :ok
  defp save(file, results), do: File.write(file, :erlang.term_to_binary(results))
end
