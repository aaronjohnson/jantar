defmodule Mix.Tasks.Jantar.Dump do
  @shortdoc "Print every sensor's current values and history as text"
  @moduledoc """
  Starts the sensors, waits for them to take a couple of samples, and prints
  what they report and what History holds: a text view usable before there is
  a renderer, and comparable with `hud --once`.

      mix jantar.dump                 one snapshot (after --wait ms, default 2200)
      mix jantar.dump --watch         refresh every 2 s until Ctrl-C
      mix jantar.dump --watch --every 1000
      mix jantar.dump --root test/fixtures/capture/t1   read a fixture tree

  The default wait lets the slowest rate sensors (the sleeping NPU, every
  2 s) take their second sample.
  """
  use Mix.Task

  alias Jantar.{Format, History, Sensor, SensorSupervisor}

  @switches [watch: :boolean, every: :integer, wait: :integer, root: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    if root = opts[:root], do: Application.put_env(:jantar, :root, Path.expand(root))
    Mix.Task.run("app.start")
    Process.sleep(opts[:wait] || 2200)

    if opts[:watch] do
      watch(opts[:every] || 2000)
    else
      IO.puts(render())
    end
  end

  defp watch(every) do
    # Home the cursor and clear the screen, then draw.
    IO.write(["\e[H\e[2J", render(), "\n"])
    Process.sleep(every)
    watch(every)
  end

  @doc false
  def render do
    host = Jantar.Frame.hostname()
    time = Time.utc_now() |> Time.truncate(:second) |> Time.to_string()
    mode = Jantar.Mode.get()

    header =
      "jantar  #{host}  #{time} UTC  " <>
        "visible=#{mode.visible} on_battery=#{mode.on_battery}"

    Enum.join([header, "", sensors_table(), "", series_table()], "\n")
  end

  # ------------------------------------------------------------------ sensors

  defp sensors_table do
    rows =
      for module <- SensorSupervisor.all() do
        name = Sensor.name_of(module)

        {status, text} =
          case History.sensor(name) do
            nil -> {"-", "not started"}
            %{status: :ok, current: c} -> {"ok", describe(name, c)}
            %{status: {:unavailable, reason}} -> {"off", "unavailable: #{inspect(reason)}"}
          end

        [to_string(name), status, interval(module), text]
      end

    table(["SENSOR", "STATUS", "EVERY", "VALUES"], rows)
  end

  defp interval(module) do
    if Process.whereis(module), do: Format.duration(Sensor.interval(module)), else: "-"
  end

  # One line per sensor, in hud's words.
  defp describe(:cpu, c) do
    tiers =
      for {tier, label} <- [{"P", "P"}, {"E", "E"}, {"LP", "L"}],
          freqs = for({f, k} <- Enum.zip(c.freqs_mhz, c.kinds), k == tier, do: f),
          freqs != [],
          do: "#{label}#{f1(Enum.sum(freqs) / length(freqs) / 1000)}"

    "load #{Format.pct(c.load)}  #{Enum.join(tiers, " ")}G  " <>
      "clock #{f1(c.clock_ghz)}G  #{length(c.ids)} cores"
  end

  defp describe(:memory, c) do
    "#{Format.pct(c.used)}  #{Format.kb(c.used_kb)} of #{Format.kb(c.total_kb)}  " <>
      "swap #{Format.kb(c.swap_used_kb)} of #{Format.kb(c.swap_total_kb)}"
  end

  defp describe(:net, c) do
    "↓#{Format.rate(c.rx)} ↑#{Format.rate(c.tx)}  " <>
      "since boot ↓#{Format.bytes(c.rx_total)} ↑#{Format.bytes(c.tx_total)}"
  end

  defp describe(:thermal, c), do: Format.temp(c.temp_c)
  defp describe(:fan, c), do: "#{c.rpm} rpm"

  defp describe(:battery, c) do
    state = String.downcase(c.status)

    state =
      if c.minutes,
        do:
          state <>
            if(c.status == "Charging", do: " full in ", else: " ") <> Format.mins(c.minutes),
        else: state

    "#{c.pct}%  #{Format.signed_watts(c.watts)}  #{state}"
  end

  defp describe(:charger, c) do
    if c.watts > 0, do: "charger #{round(c.watts)} W", else: "no charger"
  end

  defp describe(:npu, c) do
    "#{Format.pct(c.load)}  #{if c.awake, do: "awake", else: "asleep"}  " <>
      "#{c.mhz} of #{c.max_mhz} MHz  mem #{Format.bytes(c.mem_bytes || 0)}"
  end

  defp describe(:npu_counters, %{in_use_elsewhere: true}),
    do: "not streaming: another tool holds the NPU's metrics"

  defp describe(:npu_counters, %{streaming: false}), do: "idle (not streaming)"

  defp describe(:npu_counters, c) do
    "compute #{Format.pct(c[:compute])}  dma #{Format.count(c.dma)}/s  riscv #{Format.count(c.riscv)}/s  " <>
      "shave #{Format.count(c.shave)}/s  NCE #{c.nce_mhz} DPU #{c.dpu_mhz} MHz"
  end

  defp describe(:gpu, c) do
    gts =
      for gt <- c.gts do
        mhz = if gt.mhz > 0, do: "#{gt.mhz} MHz", else: "C6"
        "#{gt.name} #{Format.pct(gt.busy)} #{mhz}"
      end

    Enum.join(gts, ", ") <> "  (#{c.driver})"
  end

  defp describe(:wifi, %{ok: false}), do: "no wifi tools output"
  defp describe(:wifi, %{signal: s}) when s < 0, do: "off (not connected)"

  defp describe(:wifi, c) do
    links =
      Enum.map_join(
        c.links,
        " ",
        &(Format.band(&1.freq_mhz) <> if(&1.active, do: "●", else: "○"))
      )

    "#{c.signal}%  #{c.dbm} dBm  #{c.ssid}  #{links} #{c.width_mhz}MHz #{trunc(c.bitrate_mbit)}Mb"
  end

  defp describe(:ci_runner, c) do
    cond do
      c.job ->
        progress =
          case c.progress do
            nil ->
              "no build progress reported"

            p ->
              eta = if c.eta, do: "  ETA #{Format.age(c.eta)}", else: ""

              "#{p.package} #{trunc(p.done)}/#{trunc(p.total)} #{trunc(p.done / p.total * 100)}%#{eta}"
          end

        "job #{Format.age(c.job)}  #{c.step}  #{progress}"

      c.active ->
        "idle, waiting for a job"

      c.failed ->
        "failed"

      true ->
        "stopped"
    end
  end

  defp describe(_name, c), do: inspect(c)

  # ------------------------------------------------------------------ series

  defp series_table do
    rows =
      for series <- History.series() do
        info = History.info(series)
        values = for {_t, v} <- History.samples(series), is_number(v), do: v
        span = span(History.samples(series))

        [
          series_name(series),
          "#{info.size}/#{info.max_points}",
          Format.duration(info.window_ms),
          span,
          value(series, last_value(series)),
          value(series, values != [] && Enum.min(values)),
          value(series, values != [] && Enum.max(values)),
          value(series, values != [] && Enum.sum(values) / length(values))
        ]
      end

    table(["SERIES", "POINTS", "WINDOW", "SPAN", "LAST", "MIN", "MAX", "MEAN"], rows)
  end

  defp last_value(series) do
    case History.last(series) do
      {_t, v} -> v
      nil -> nil
    end
  end

  # How much time the held samples cover.
  defp span([]), do: "-"
  defp span([{t0, _} | _] = samples), do: Format.duration(elem(List.last(samples), 0) - t0)

  defp series_name({kind, name}), do: "#{kind}:#{name}"
  defp series_name(name), do: to_string(name)

  # Each series in its own units.
  defp value(_series, v) when v in [nil, false], do: "-"
  defp value(s, v) when s in [:cpu, :mem, :npu], do: Format.pct(v)
  defp value({:gpu, _}, v), do: Format.pct(v)
  defp value(s, v) when s in [:rx, :tx], do: Format.rate(v) <> "/s"
  defp value(:temp, v), do: Format.temp(v)
  defp value(:clock, v), do: "#{:erlang.float_to_binary(v / 1, decimals: 2)}G"
  defp value(:power, v), do: Format.signed_watts(v)
  defp value(:fan, v), do: "#{round(v)}"
  defp value(:wifi, v), do: "#{round(v)}%"
  defp value(_series, v), do: inspect(v)

  # ------------------------------------------------------------------ helpers

  defp f1(nil), do: "…"
  defp f1(x), do: :erlang.float_to_binary(x / 1, decimals: 1)

  # Left-aligned columns, the last one unpadded.
  defp table(header, rows) do
    all = [header | rows]
    columns = length(header)

    widths =
      for i <- 0..(columns - 2),
          do: all |> Enum.map(&String.length(Enum.at(&1, i))) |> Enum.max()

    Enum.map_join(all, "\n", fn row ->
      padded = Enum.zip_with(Enum.drop(row, -1), widths, &String.pad_trailing(&1, &2 + 2))
      Enum.join(padded) <> List.last(row)
    end)
  end
end
