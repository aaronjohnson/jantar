defmodule Jantar.Frame.Demo do
  @moduledoc """
  A made-up but realistic snapshot for `Jantar.Frame`: half an hour of
  history at the real sampling rates (so 250 ms series are dense and drawn as
  bands), every sensor present, and a CI build in progress. Deterministic
  (seeded random numbers), so it serves golden tests and side-by-side
  backend comparisons: `mix jantar.png --demo`.
  """

  @now 10_000_000

  def snapshot do
    :rand.seed(:exsss, {1, 2, 3})

    series = %{
      :cpu => series(300_000, 250, fn t -> busy(t, 0.12, 0.55) end),
      :clock => series(1_800_000, 1000, fn t -> 1.2 + 1.6 * wave(t, 400_000) + noise(0.3) end),
      :mem => series(300_000, 1000, fn t -> 0.31 + 0.02 * wave(t, 120_000) end),
      :rx => series(300_000, 250, fn t -> burst(t, 2.0e4, 4.0e6) end),
      :tx => series(300_000, 250, fn t -> burst(t, 5.0e3, 3.0e5) end),
      :temp => series(1_800_000, 500, fn t -> 52 + 30 * wave(t, 400_000) + noise(2) end),
      :power =>
        series(1_800_000, 1000, fn t ->
          if t > 1_200_000, do: 24 + noise(4), else: -(9 + 6 * wave(t, 300_000) + noise(1.5))
        end),
      :fan => series(1_800_000, 1000, fn t -> 1800 + 2600 * wave(t, 400_000) + noise(60) end),
      :npu =>
        series(300_000, 250, fn t ->
          if rem(div(t, 40_000), 3) == 0, do: 0.05 + noise(0.04), else: 0.0
        end),
      :wifi => series(1_800_000, 20_000, fn _t -> 58 + noise(5) end),
      # An inference job for 40 s of every 120 s; the counters only run then.
      {:npu, :dma} => series(300_000, 1000, fn t -> npu_job(t, 3.0e9) end),
      {:npu, :compute} => series(300_000, 1000, fn t -> npu_job(t, 0.04) end),
      {:npu, :riscv} => series(300_000, 1000, fn t -> npu_job(t, 1.9e7) end),
      {:npu, :shave} => series(300_000, 1000, fn t -> npu_job(t, 7.3e3) end),
      {:gpu, "gt0-rc"} => series(300_000, 250, fn t -> busy(t, 0.02, 0.3) end),
      {:gpu, "gt1-mc"} => series(300_000, 250, fn t -> busy(t, 0.002, 0.02) end),
      # The link went down for a minute 19 minutes ago, after a roam.
      {:link, :gateway} =>
        series(1_800_000, 2000, fn t -> if t in 660_000..720_000, do: 0, else: 1 end),
      # A little swapping during a build 20 minutes ago.
      {:swap, :in} =>
        series(1_800_000, 1000, fn t -> if t in 500_000..700_000, do: 40 + noise(30), else: 0 end),
      {:swap, :out} =>
        series(1_800_000, 1000, fn t ->
          if t in 450_000..650_000, do: 300 + noise(200), else: 0
        end),
      {:disk, :read} => series(300_000, 1000, fn t -> burst(t, 2.0e4, 6.0e7) end),
      {:disk, :write} => series(300_000, 1000, fn t -> burst(t, 5.0e4, 2.0e7) end),
      {:rapl, :platform} =>
        series(1_800_000, 1000, fn t -> 6 + 9 * wave(t, 400_000) + noise(0.8) end),
      {:rapl, :package} =>
        series(1_800_000, 1000, fn t -> 2.5 + 7 * wave(t, 400_000) + noise(0.6) end),
      {:rapl, :cores} =>
        series(1_800_000, 1000, fn t -> 1.0 + 5 * wave(t, 400_000) + noise(0.4) end),
      {:rapl, :graphics} =>
        series(1_800_000, 1000, fn t -> 0.3 + 0.8 * wave(t, 90_000) + noise(0.1) end),
      {:rapl, :memory} => series(1_800_000, 1000, fn _t -> 0.6 + noise(0.05) end),
      {:link, :ipv6} =>
        series(1_800_000, 2000, fn t -> if t in 600_000..1_200_000, do: 1, else: 0 end),
      {:event, :wifi} => events([{1_320_000, 1}, {1_140_000, -1}, {1_110_000, 1}]),
      {:event, :link} => events([{1_135_000, -2}, {1_085_000, 2}])
    }

    kinds = List.duplicate("P", 4) ++ List.duplicate("E", 8) ++ List.duplicate("LP", 4)

    sensors = %{
      cpu: %{
        load: 0.34,
        core_loads: for(i <- 0..15, do: abs(:math.sin(i * 1.7)) * 0.9),
        ids: Enum.to_list(0..15),
        kinds: kinds,
        max_mhz:
          List.duplicate(4700.0, 4) ++ List.duplicate(3700.0, 8) ++ List.duplicate(3300.0, 4),
        freqs_mhz: for(i <- 0..15, do: 400.0 + 3000 * abs(:math.cos(i))),
        clock_ghz: 2.1
      },
      memory: %{
        total_kb: 65_309_752,
        available_kb: 45_000_000,
        used_kb: 20_309_752,
        used: 0.311,
        swap_total_kb: 67_108_860,
        swap_used_kb: 0
      },
      net: %{rx: 1.3e6, tx: 4.2e4, rx_total: 28_000_000_000, tx_total: 3_100_000_000},
      thermal: %{temp_c: 71.0, path: "/sys/class/hwmon/hwmon5/temp1_input"},
      fan: %{rpm: 3400, path: "/sys/class/hwmon/hwmon7/fan1_input"},
      battery: %{status: "Charging", watts: 24.3, pct: 81, minutes: 38.0},
      charger: %{watts: 100.0, port: "/sys/class/power_supply/ucsi-source-psy-USBC000:002"},
      npu: %{load: 0.06, awake: true, mhz: 1400, max_mhz: 2050, mem_bytes: 68_714_496.0},
      npu_counters: %{
        streaming: true,
        dma: 3.1e9,
        dma0: 1.65e9,
        dma1: 1.45e9,
        riscv: 1.9e7,
        shave: 7.3e3,
        compute: 0.046,
        nce_mhz: 543,
        dpu_mhz: 950
      },
      gpu: %{
        driver: "xe",
        gts: [
          %{name: "gt0-rc", busy: 0.21, mhz: 1650, max_mhz: 2500.0},
          %{name: "gt1-mc", busy: 0.01, mhz: 0, max_mhz: 1200.0}
        ]
      },
      wifi: %{
        ok: true,
        signal: 61,
        ssid: "Network-4",
        dbm: -57,
        width_mhz: 320,
        bitrate_mbit: 1152.9,
        links: [%{id: 1, freq_mhz: 5180, active: false}, %{id: 2, freq_mhz: 6375, active: true}]
      },
      link: %{route: true, gateway: true, iface: "wlan0", gateway_ip: "192.0.2.1", ipv6: false},
      ports: %{
        ports: [
          %{
            port: "port0",
            bay: "right back",
            partner: false,
            role: :sink,
            charger: nil,
            devices: []
          },
          %{
            port: "port1",
            bay: "right front",
            partner: true,
            role: :source,
            charger: nil,
            devices: ["Security key"]
          },
          %{
            port: "port2",
            bay: "left front",
            partner: false,
            role: :sink,
            charger: nil,
            devices: []
          },
          %{
            port: "port3",
            bay: "left back",
            partner: true,
            role: :sink,
            charger: %{volts: 20.0, amps: 5.0, watts: 100.0},
            devices: []
          }
        ],
        other: []
      },
      rapl: %{platform: 11.2, package: 6.4, cores: 3.9, graphics: 0.7, memory: 0.6},
      swap: %{in: 0.0, out: 0.0, used_kb: 812_000, total_kb: 67_108_860},
      disk: %{
        device: "nvme0n1",
        read: 1.8e6,
        write: 4.2e5,
        temp_c: 41.0,
        top: {"nix-daemon", 3.1e5}
      },
      wifi_events: %{iface: "wlan0", bssid: "00:00:5e:00:53:04"},
      ci_runner: %{
        installed: true,
        active: true,
        failed: false,
        job: 2412.0,
        step: "nix build .#openvino",
        readable: true,
        progress: %{package: "llvm-21.1.0", done: 2730.0, total: 4120.0},
        eta: 1260.0
      }
    }

    %{now: @now, series: series, sensors: sensors}
  end

  # Events `{age_ms, code}` in a 30 min window.
  defp events(list) do
    %{
      samples: for({age, code} <- Enum.reverse(list), do: {@now - age, code}),
      window_ms: 1_800_000
    }
  end

  # A series sampled every `every` ms over `window` ms ending now, as History holds it.
  defp series(window, every, fun) do
    # nil is a gap (no reading).
    samples =
      for age <- window..0//-every,
          do: {@now - age, with(v when is_number(v) <- fun.(window - age), do: v / 1)}

    %{samples: samples, window_ms: window}
  end

  # Busy around `rate` for 40 s of every 120 s (ending at the newest sample),
  # nil (not measured) the rest of the time.
  defp npu_job(t, rate),
    do: if(rem(t, 120_000) >= 80_000, do: rate * (0.8 + 0.4 * :rand.uniform()), else: nil)

  defp wave(t, period), do: (1 + :math.sin(2 * :math.pi() * t / period)) / 2
  defp noise(scale), do: (:rand.uniform() - 0.5) * 2 * scale

  defp busy(t, base, peak),
    do: max(0.0, min(1.0, base + (peak - base) * wave(t, 90_000) ** 4 + noise(base)))

  defp burst(t, base, peak),
    do:
      max(
        0.0,
        base * (1 + noise(0.5)) +
          if(rem(div(t, 7000), 9) == 0, do: peak * :rand.uniform(), else: 0)
      )
end
