defmodule BeamHud.Sensors.CiRunner do
  @moduledoc """
  The self-hosted GitHub Actions runner (hud's read_runner): is it installed,
  running, failed; how long the current job has run; the build step and
  progress the job writes to ci-status/{step,progress}; and an ETA from the
  progress rate over the last 5 minutes (Gleam `rate.eta_update`).

  No series, just current values, every 2 s. "Not installed" (no unit file)
  counts as unavailable, so the sensor backs off.
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.{Core, Sysfs}

  @unit "github-runner-nixos-intel-npu.service"
  @cgroup "/sys/fs/cgroup/system.slice/#{@unit}/"
  @unit_file "/etc/systemd/system/#{@unit}"
  @status_dir "/run/github-runner/nixos-intel-npu/ci-status/"

  # Linux reports process start times in clock ticks of USER_HZ, which is 100
  # on every mainstream architecture (hud asks sysconf(SC_CLK_TCK)).
  @clk_tck 100

  @impl true
  def defaults do
    [
      interval: 2_000,
      failed_every: 30_000,
      failed_command: ["systemctl", "is-failed", "--quiet", @unit]
    ]
  end

  @impl true
  def init(opts) do
    if Sysfs.exists?(opts[:root], @unit_file) do
      state = %{
        root: opts[:root],
        failed_every: opts[:failed_every],
        failed_command: opts[:failed_command],
        failed_at: nil,
        failed: false,
        eta: :hud_core@rate.eta_new()
      }

      {:ok, state, []}
    else
      {:unavailable, :runner_not_installed}
    end
  end

  @impl true
  def sample(state, now) do
    if not Sysfs.exists?(state.root, @unit_file) do
      {:unavailable, :runner_not_installed, state}
    else
      events = Sysfs.read(state.root, @cgroup <> "cgroup.events") || ""
      active = :hud_core@parse.cgroup_populated(events)
      state = if active, do: %{state | failed: false}, else: check_failed(state, now)
      job = if active, do: job_seconds(state.root)
      {current, state} = progress(state, job, now)

      {:ok, [],
       Map.merge(current, %{installed: true, active: active, failed: state.failed, job: job}),
       state}
    end
  end

  # How long the Runner.Worker process has run, in seconds; nil when the
  # runner is idle (only its listener is running).
  defp job_seconds(root) do
    pids = :hud_core@parse.pids(Sysfs.read(root, @cgroup <> "cgroup.procs") || "")

    started =
      Enum.find_value(pids, fn pid ->
        cmdline = Sysfs.read_raw(root, "/proc/#{pid}/cmdline") || ""

        if String.contains?(cmdline, "Runner.Worker") do
          Core.ok_or_nil(
            :hud_core@parse.proc_start_ticks(Sysfs.read(root, "/proc/#{pid}/stat") || "")
          )
        end
      end)

    uptime = Core.ok_or_nil(:hud_core@parse.uptime(Sysfs.read(root, "/proc/uptime") || ""))
    if started && uptime, do: max(0.0, uptime - started / @clk_tck)
  end

  # Step and progress are only meaningful during a job.
  defp progress(state, nil, _now) do
    {%{step: "", progress: nil, eta: nil, readable: true},
     %{state | eta: :hud_core@rate.eta_new()}}
  end

  defp progress(state, _job, now) do
    step = Sysfs.read(state.root, @status_dir <> "step")
    prog_text = Sysfs.read(state.root, @status_dir <> "progress")

    # Nothing read because we lack permission on ci-status is worth saying so.
    denied = match?({:error, :eacces}, File.ls(Sysfs.path(state.root, @status_dir)))
    readable = not (step == nil and prog_text == nil and denied)

    case Core.ci_progress(prog_text) do
      nil ->
        {%{step: step || "", progress: nil, eta: nil, readable: readable},
         %{state | eta: :hud_core@rate.eta_new()}}

      progress ->
        {eta, estimate} =
          :hud_core@rate.eta_update(state.eta, now, Core.progress_record(progress))

        {%{step: step || "", progress: progress, eta: Core.option(estimate), readable: readable},
         %{state | eta: eta}}
    end
  end

  # `systemctl is-failed` at most every 30 s while the runner isn't running.
  defp check_failed(%{failed_command: nil} = state, _now), do: state

  defp check_failed(state, now) do
    if state.failed_at == nil or now - state.failed_at >= state.failed_every do
      [exe | args] = state.failed_command

      failed =
        case System.find_executable(exe) do
          nil -> false
          path -> elem(System.cmd(path, args, stderr_to_stdout: true), 1) == 0
        end

      %{state | failed: failed, failed_at: now}
    else
      state
    end
  end
end
