defmodule Jantar.Sensors.CiRunnerTest do
  @moduledoc """
  The CI runner source over a synthetic tree (the recorded snapshot only has an
  idle runner): a job's age from the worker's start time, step and progress
  from ci-status, and the ETA once progress spans a minute.
  """
  use ExUnit.Case, async: true

  import Jantar.Fixtures
  alias Jantar.Sensors.CiRunner

  @moduletag :tmp_dir

  @unit "github-runner-nixos-intel-npu.service"
  @cgroup "/sys/fs/cgroup/system.slice/#{@unit}/"
  @status "/run/github-runner/nixos-intel-npu/ci-status/"

  defp runner(dir, extra) do
    # The worker (pid 200) started 5000 s after boot (500000 ticks at 100 Hz);
    # field 22 of its stat line. Uptime is 5600 s, so the job has run 600 s.
    stat =
      "200 (Runner.Worker) S " <> Enum.join(Enum.map(4..21, &to_string/1), " ") <> " 500000 0 0\n"

    write_tree(
      dir,
      Map.merge(
        %{
          "/etc/systemd/system/#{@unit}" => "",
          (@cgroup <> "cgroup.events") => "populated 1\nfrozen 0\n",
          (@cgroup <> "cgroup.procs") => "100\n200\n",
          "/proc/100/cmdline" => "/opt/runner/bin/Runner.Listener\0run\0",
          "/proc/200/cmdline" => "/opt/runner/bin/Runner.Worker\0spawnclient\0",
          "/proc/200/stat" => stat,
          "/proc/uptime" => "5600.00 9000.00\n"
        },
        extra
      )
    )
  end

  defp start(dir, opts \\ []) do
    {:ok, state, []} = CiRunner.init(Jantar.Sensor.options(CiRunner, [root: dir] ++ opts))
    state
  end

  defp progress(dir, line), do: write_tree(dir, %{(@status <> "progress") => line})

  test "a running job with progress and an ETA", %{tmp_dir: dir} do
    runner(dir, %{(@status <> "step") => "Building LLVM\n"})
    state = start(dir)

    progress(dir, "llvm 100 1000\n")
    {:ok, [], c, state} = CiRunner.sample(state, 0)
    assert c.active and c.installed and not c.failed
    assert c.job == 600.0
    assert c.step == "Building LLVM"
    assert c.progress == %{package: "llvm", done: 100.0, total: 1000.0}
    assert c.eta == nil

    progress(dir, "llvm 130 1000\n")
    {:ok, [], c, state} = CiRunner.sample(state, 30_000)
    # Under a minute of history: no estimate yet.
    assert c.eta == nil

    progress(dir, "llvm 200 1000\n")
    {:ok, [], c, _state} = CiRunner.sample(state, 100_000)
    # 100 packages in 100 s; 800 to go.
    assert c.eta == 800.0
  end

  test "an idle runner: active, no job, no progress", %{tmp_dir: dir} do
    runner(dir, %{(@cgroup <> "cgroup.procs") => "100\n", (@status <> "progress") => "llvm 1 2\n"})

    {:ok, [], c, _} = CiRunner.sample(start(dir), 0)
    assert c.active
    assert c.job == nil
    assert c.progress == nil
  end

  test "a stopped runner asks systemd whether it failed", %{tmp_dir: dir} do
    runner(dir, %{(@cgroup <> "cgroup.events") => "populated 0\nfrozen 0\n"})

    # `true` exits 0, as `systemctl is-failed --quiet` does for a failed unit.
    {:ok, [], c, _} = CiRunner.sample(start(dir, failed_command: ["true"]), 0)
    refute c.active
    assert c.failed

    {:ok, [], c, _} = CiRunner.sample(start(dir, failed_command: ["false"]), 0)
    refute c.failed
  end

  test "not installed is unavailable", %{tmp_dir: dir} do
    assert CiRunner.init(Jantar.Sensor.options(CiRunner, root: dir)) ==
             {:unavailable, :runner_not_installed}
  end
end
