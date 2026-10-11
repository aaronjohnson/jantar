defmodule Jantar.NpuCountersTest do
  @moduledoc """
  The NPU counters sensor against a stand-in port (no NPU needed, and none
  woken), and the real npu_port program's protocol where it needs no NPU.
  """
  use ExUnit.Case, async: true

  import Jantar.Fixtures
  alias Jantar.NpuPort
  alias Jantar.Sensors.NpuCounters

  @moduletag :tmp_dir
  @dev "/sys/class/accel/accel0/device/"
  @layout [
    {"NOC", ["NOC_noc", "NOC_DMA_00", "NOC_DMA_01", "L2C_Riscv", "NOC_timestamp", "L2C_Shave"]},
    {"FREQ", ["Freq_dpu_hz", "Freq_nce_hz", "Freq_timestamp"]}
  ]

  # A stand-in for Jantar.NpuPort: logs each call in the test process and
  # answers reads from a queue.
  defmodule FakePort do
    def exe, do: "/nonexistent"
    def start(_opts), do: log(:start) && make_ref()
    def stop(_port), do: log(:stop) && :ok
    def open(_port, _groups), do: log(:open) && Process.get(:open_reply, {:ok, :layout})
    def close(_port), do: log(:close) && :ok

    def read(_port, _layout) do
      log(:read)
      [reply | rest] = Process.get(:reads)
      Process.put(:reads, rest)
      reply
    end

    defp log(call), do: Process.put(:calls, Process.get(:calls, []) ++ [call]) || true
  end

  defp npu(dir, busy, status) do
    write_tree(dir, %{
      (@dev <> "npu_busy_time_us") => "#{busy}\n",
      (@dev <> "power/runtime_status") => status <> "\n"
    })
  end

  defp init(dir, opts \\ []) do
    exe = Path.join(dir, "npu_port")
    File.write!(exe, "")
    opts = [root: dir, exe: exe, port_module: FakePort] ++ opts
    NpuCounters.init(Jantar.Sensor.options(NpuCounters, opts))
  end

  # One NOC report: cumulative DMA, RISC-V, SHAVE at a timestamp in ticks.
  defp noc(dma, riscv, shave, ticks) do
    {"NOC", 3,
     %{
       "NOC_noc" => dma,
       "NOC_DMA_00" => dma / 2,
       "NOC_DMA_01" => dma / 2,
       "L2C_Riscv" => riscv,
       "L2C_Shave" => shave,
       "NOC_timestamp" => ticks
     }}
  end

  # One FRC report: NCE cycles counted, at a timestamp in ticks.
  defp frc(cycles, ticks),
    do: {"FRC", 3, %{"FRC_Fixed" => ticks, "FRC_Dynamic" => cycles, "FRC_timestamp" => ticks}}

  defp freq(dpu_khz, nce_khz),
    do: {"FREQ", 2, %{"Freq_dpu_hz" => dpu_khz, "Freq_nce_hz" => nce_khz, "Freq_timestamp" => 1}}

  test "unavailable without an NPU, without the program, or when disabled", %{tmp_dir: dir} do
    assert init(dir) == {:unavailable, :no_npu}
    npu(dir, 0, "suspended")
    assert {:ok, _, _} = init(dir)
    assert init(dir, enabled: false) == {:unavailable, :disabled}

    assert NpuCounters.init(root: dir, exe: Path.join(dir, "missing"), enabled: true) ==
             {:unavailable, :no_npu_port}
  end

  test "streams only while the NPU works, then lets it sleep", %{tmp_dir: dir} do
    npu(dir, 1000, "suspended")
    {:ok, s, series} = init(dir)

    assert for({name, 300_000} <- series, do: name) ==
             [{:npu, :compute}, {:npu, :dma}, {:npu, :riscv}, {:npu, :shave}]

    # Asleep, busy time still: nothing touches the NPU.
    {:ok, [], c, s} = NpuCounters.sample(s, 0)
    {:ok, [], _, s} = NpuCounters.sample(s, 2000)
    assert Process.get(:calls) == nil
    refute c.streaming
    assert NpuCounters.next_interval(s, 1000) == 2000

    # Awake, but our own wake (busy time unchanged) doesn't count either.
    npu(dir, 1000, "active")
    {:ok, [], _, s} = NpuCounters.sample(s, 3000)
    assert Process.get(:calls) == nil

    # Work starts: the port starts and the streamers open.
    npu(dir, 5000, "active")
    {:ok, [], c, s} = NpuCounters.sample(s, 4000)
    assert Process.get(:calls) == [:start, :open]
    assert c.streaming
    assert NpuCounters.next_interval(s, 1000) == 1000

    # First read is the baseline, the second gives rates per second of NPU
    # time (19.2 MHz ticks: 1 s here).
    Process.put(:reads, [
      {:ok, [noc(1.0e9, 1.0e6, 100.0, 1_000_000), frc(0, 1_000_000), freq(950_000, 542_857)]},
      # 1 s at 543 MHz, the clock on for 25% of it.
      {:ok,
       [
         noc(4.0e9, 2.9e7, 7400.0, 20_200_000),
         frc(0.25 * 543.0e6, 20_200_000),
         {"FREQ", 0, %{}}
       ]}
    ])

    npu(dir, 9000, "active")
    {:ok, [], _, s} = NpuCounters.sample(s, 5000)
    npu(dir, 13000, "active")
    {:ok, readings, c, s} = NpuCounters.sample(s, 6000)
    readings = Map.new(readings)
    assert_in_delta readings[{:npu, :dma}], 3.0e9, 1
    assert_in_delta readings[{:npu, :riscv}], 2.8e7, 1.0e-3
    assert_in_delta readings[{:npu, :shave}], 7300.0, 1.0e-6
    assert_in_delta readings[{:npu, :compute}], 0.25, 1.0e-9
    assert_in_delta c.dma0, 1.5e9, 1
    # The clocks come in kHz; kept when a read has no FREQ report.
    assert {c.dpu_mhz, c.nce_mhz} == {950, 543}

    # Work stops: close, and a gap in each series.
    {:ok, gaps, c, s} = NpuCounters.sample(s, 7000)
    assert gaps == for(k <- [:compute, :dma, :riscv, :shave], do: {{:npu, k}, nil})
    refute c.streaming
    assert List.last(Process.get(:calls)) == :close

    # Asleep again: no more calls; the program stays, idle, for next time.
    npu(dir, 13000, "suspended")
    calls = Process.get(:calls)
    {:ok, [], _, s} = NpuCounters.sample(s, 9000)
    assert Process.get(:calls) == calls
    assert NpuCounters.next_interval(s, 1000) == 2000
  end

  test "a port error makes the sensor unavailable and stops the program", %{tmp_dir: dir} do
    npu(dir, 0, "active")
    {:ok, s, _} = init(dir)
    {:ok, _, _, s} = NpuCounters.sample(s, 0)
    Process.put(:open_reply, {:error, "no metric group NOC"})
    npu(dir, 10, "active")

    assert {:unavailable, {:npu_port, "no metric group NOC"}, s} = NpuCounters.sample(s, 1000)
    assert Process.get(:calls) == [:start, :open, :stop]
    assert s.port == nil
  end

  test "streamers held by another tool: wait and retry, not unavailable", %{tmp_dir: dir} do
    npu(dir, 0, "active")
    {:ok, s, _} = init(dir)
    {:ok, _, _, s} = NpuCounters.sample(s, 0)
    Process.put(:open_reply, {:error, "zetMetricStreamerOpen NOC: 0x7ffffffe"})

    npu(dir, 10, "active")
    assert {:ok, [], c, s} = NpuCounters.sample(s, 1000)
    assert c.in_use_elsewhere and not c.streaming

    # Still working, but no new attempt within 30 s.
    npu(dir, 20, "active")
    {:ok, [], _, s} = NpuCounters.sample(s, 2000)
    assert Process.get(:calls) == [:start, :open]

    # Free again later.
    Process.put(:open_reply, {:ok, :layout})
    npu(dir, 30, "active")
    {:ok, [], c, _} = NpuCounters.sample(s, 31_001)
    assert Process.get(:calls) == [:start, :open, :open]
    assert c.streaming and not c.in_use_elsewhere
  end

  test "npu_port: protocol round trip, without opening the NPU" do
    port = NpuPort.start(driver_path: "/nonexistent")
    assert NpuPort.echo(port, "hello") == {:ok, "hello"}
    assert {:error, "not open"} = NpuPort.read(port, @layout)
    assert NpuPort.close(port) == :ok
    NpuPort.stop(port)
    assert NpuPort.echo(port, "x") == {:error, :closed}
  end

  test "npu_port: a program that dies is an error, not a crash", %{tmp_dir: dir} do
    exe = Path.join(dir, "dies")
    File.write!(exe, "#!/bin/sh\nexit 3\n")
    File.chmod!(exe, 0o755)
    port = NpuPort.start(exe: exe)
    assert NpuPort.open(port, ["NOC"]) in [{:error, {:exited, 3}}, {:error, :closed}]
  end
end
