defmodule BeamHud.Sensors.Wifi do
  @moduledoc """
  Wifi signal, network and links, from the same shell command hud runs (nmcli
  for signal and SSID, iw for MLO links, width, dBm and bitrate), every 20 s
  (hud's read_wifi / take_wifi). Series `:wifi` (signal 0..100, or nil when
  not connected; 30 min).

  The command can take a while, but it only blocks this sensor's own process;
  hud needed a thread for that. It is killed after `:timeout` ms.
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.Core

  @command """
  nmcli -t -f IN-USE,SIGNAL,SSID device wifi list --rescan no; echo @@IW; \
  command -v iw >/dev/null && for i in $(iw dev | awk '/Interface/{print $2}'); \
  do iw dev "$i" info; iw dev "$i" link; done\
  """

  @impl true
  def defaults, do: [interval: 20_000, timeout: 10_000, command: ["sh", "-c", @command]]

  @impl true
  def init(opts) do
    [exe | _] = opts[:command]

    if System.find_executable(exe) do
      {:ok, %{command: opts[:command], timeout: opts[:timeout]}, [wifi: 30 * 60_000]}
    else
      {:unavailable, {:not_found, exe}}
    end
  end

  @impl true
  def sample(state, _now) do
    wifi = Core.wifi(run(state.command, state.timeout))
    signal = if wifi.signal >= 0, do: wifi.signal
    {:ok, [wifi: signal], wifi, state}
  end

  # The command's stdout, or "" if it failed or timed out (hud: ok = false).
  defp run([exe | args], timeout) do
    task =
      Task.async(fn ->
        try do
          {out, _status} = System.cmd(exe, args, stderr_to_stdout: false)
          out
        rescue
          _ -> ""
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, out} -> out
      _ -> ""
    end
  end
end
