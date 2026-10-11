defmodule Jantar.SensorsTest do
  @moduledoc """
  Each source module against the recorded snapshots of this machine: sample
  the t0 tree at time 0, copy t1 over it, sample again 2520 ms later (the
  snapshots' /proc/uptime difference), and compare with what hud computed
  from the same files (hud_expected.json, from tools/hud_oracle.py).

  These call the modules' `init/1` and `sample/2` directly: no processes.
  """
  use ExUnit.Case, async: true

  import Jantar.Fixtures
  alias Jantar.Sensors.{Battery, Charger, Cpu, Fan, Gpu, Memory, Net, Npu, Thermal, Wifi}

  @moduletag :tmp_dir
  @dt 2520

  # Run a source over t0 then t1; return the readings and current values at t1.
  defp two_samples(module, dir, opts \\ []) do
    load_snapshot(dir, "t0")
    {:ok, state, series} = module.init(Jantar.Sensor.options(module, [root: dir] ++ opts))
    {:ok, _readings, _current, state} = module.sample(state, 0)
    load_snapshot(dir, "t1")
    {:ok, readings, current, _state} = module.sample(state, @dt)
    {series, Map.new(readings), current}
  end

  setup_all do
    %{hud: expected()}
  end

  test "cpu: load per core, tiers and clock match hud", %{tmp_dir: dir, hud: hud} do
    {series, readings, c} = two_samples(Cpu, dir)
    assert series == [cpu: 300_000, clock: 1_800_000]

    assert close?(readings.cpu, hud["cpu_load"])
    assert length(c.core_loads) == 16

    for {ours, theirs} <- Enum.zip(c.core_loads, hud["core_load"]),
        do: assert(close?(ours, theirs))

    assert c.kinds == hud["kinds"]
    assert c.max_mhz == hud["max_mhz"]
    assert c.freqs_mhz == hud["freqs_mhz"]
    assert close?(readings.clock, hud["clock_ghz"])
  end

  test "cpu: the first sample has no load yet", %{tmp_dir: dir} do
    load_snapshot(dir, "t0")
    {:ok, state, _} = Cpu.init(root: dir, clock_every: 1000)
    {:ok, readings, current, _} = Cpu.sample(state, 0)
    refute Keyword.has_key?(readings, :cpu)
    assert current.load == nil
    # The clock needs only one reading.
    assert Keyword.has_key?(readings, :clock)
  end

  test "cpu: tiers without hybrid info are blank, LP needs a slower group" do
    assert Cpu.kinds([0, 1], [3000.0, 3000.0], []) == ["", ""]
    assert Cpu.kinds([0, 1, 2], [4000.0, 3000.0, 3000.0], [0]) == ["P", "E", "E"]
    assert Cpu.kinds([0, 1, 2], [4000.0, 3000.0, 2000.0], [0]) == ["P", "E", "LP"]
  end

  test "memory matches hud", %{tmp_dir: dir, hud: hud} do
    {_, readings, c} = two_samples(Memory, dir)
    assert close?(readings.mem, hud["mem_used"])
    assert c.total_kb == hud["mem_total_kb"]
  end

  test "net: rates and totals match hud", %{tmp_dir: dir, hud: hud} do
    {_, readings, c} = two_samples(Net, dir)
    assert close?(readings.rx, hud["rx"])
    assert close?(readings.tx, hud["tx"])
    assert {c.rx_total, c.tx_total} == {hud["rx_total"], hud["tx_total"]}
  end

  test "thermal finds the coretemp package sensor", %{tmp_dir: dir, hud: hud} do
    {_, readings, c} = two_samples(Thermal, dir)
    assert c.path == hud["temp_path"]
    assert readings.temp == hud["temp"]
  end

  test "fan prefers cros_ec over acpi_fan", %{tmp_dir: dir, hud: hud} do
    {_, readings, c} = two_samples(Fan, dir)
    # hwmon1 (acpi_fan) also has a fan1_input; hud picks cros_ec (hwmon7).
    assert c.path == hud["fan_path"]
    assert readings.fan == hud["fan"]
  end

  test "battery and charger match hud", %{tmp_dir: dir, hud: hud} do
    {_, readings, c} = two_samples(Battery, dir)
    assert readings.power == hud["bat"]["watts"]
    assert c.pct == hud["bat"]["pct"]
    assert c.status == hud["bat"]["status"]
    assert c.minutes == hud["bat"]["mins"]

    {_, _, charger} = two_samples(Charger, dir)
    assert charger.watts == hud["bat"]["charger"]
  end

  test "battery: discharging is negative, with time to empty", %{tmp_dir: dir} do
    write_tree(dir, %{
      "/sys/class/power_supply/BAT1/status" => "Discharging\n",
      "/sys/class/power_supply/BAT1/current_now" => "1500000\n",
      "/sys/class/power_supply/BAT1/voltage_now" => "15400000\n",
      "/sys/class/power_supply/BAT1/capacity" => "57\n",
      "/sys/class/power_supply/BAT1/charge_now" => "2250000\n",
      "/sys/class/power_supply/BAT1/charge_full" => "4500000\n"
    })

    {:ok, state, _} = Battery.init(root: dir, detail_every: 10_000)
    {:ok, [power: watts], c, _} = Battery.sample(state, 0)
    assert close?(watts, -23.1)
    assert c.pct == 57
    # 2.25 Ah at 1.5 A = 90 min.
    assert c.minutes == 90.0
    assert Jantar.Mode.get().on_battery
    Jantar.Mode.set(:on_battery, false)
  end

  test "npu: load and sleep state match hud; slower while asleep", %{tmp_dir: dir, hud: hud} do
    {_, readings, c} = two_samples(Npu, dir)
    assert readings.npu == hud["npu"]["load"]
    assert c.awake == hud["npu"]["awake"]
    assert c.mhz == hud["npu"]["mhz"]
    assert c.max_mhz == hud["npu"]["max"]
    assert c.mem_bytes == hud["npu"]["mem"]

    assert Npu.next_interval(%{awake: false, idle_interval: 2000}, 250) == 2000
    assert Npu.next_interval(%{awake: true, idle_interval: 2000}, 250) == 250
  end

  test "gpu: one series per GT, busy matches hud", %{tmp_dir: dir, hud: hud} do
    {series, readings, c} = two_samples(Gpu, dir)
    assert series == [{{:gpu, "gt0-rc"}, 300_000}, {{:gpu, "gt1-mc"}, 300_000}]
    assert c.driver == hud["gpu_driver"]

    for {gt, theirs} <- Enum.zip(c.gts, hud["gpu"]) do
      assert gt.name == theirs["name"]
      assert gt.mhz == theirs["mhz"]
      assert gt.max_mhz == theirs["max"]
      # hud's interval is a float from /proc/uptime, ours whole ms: 1e-6.
      assert close?(readings[{:gpu, gt.name}], theirs["busy"], 1.0e-6)
    end
  end

  test "wifi parses the command output like hud", %{hud: hud} do
    wifi_txt = Path.join(snapshot("t1"), "wifi.txt")
    {:ok, state, [wifi: 1_800_000]} = Wifi.init(command: ["cat", wifi_txt], timeout: 5000)
    {:ok, [wifi: signal], c, _} = Wifi.sample(state, 0)

    w = hud["wifi"]
    assert signal == w["signal"]

    assert {c.ssid, c.dbm, c.width_mhz, c.bitrate_mbit} ==
             {w["ssid"], w["dbm"], w["width"], w["bitrate"]}

    assert for(l <- c.links, do: [l.id, l.freq_mhz, l.active]) == w["links"]
  end

  test "wifi: a failing or hanging command reads as no output" do
    {:ok, state, _} = Wifi.init(command: ["sleep", "5"], timeout: 50)
    {:ok, [wifi: nil], c, _} = Wifi.sample(state, 0)
    refute c.ok
  end

  test "every source is unavailable, not crashing, on an empty root", %{tmp_dir: dir} do
    for module <- Jantar.SensorSupervisor.all() -- [Wifi] do
      assert {:unavailable, _reason} = module.init(Jantar.Sensor.options(module, root: dir)),
             "#{inspect(module)} should be unavailable"
    end

    assert {:unavailable, {:not_found, _}} = Wifi.init(command: ["no-such-tool-here"], timeout: 1)
  end
end
