defmodule Jantar.WifiEvents do
  @moduledoc """
  Wi-Fi connects and disconnects the moment they happen, from `iw event`
  held open as a Port: the kernel's nl80211 events, so nothing polls. Each
  connection (a first connect or a roam to another access point or band) is
  pushed to `{:event, :wifi}` as `1`, each disconnect as `-1`; the network
  dials draw them as radial lines. The access point joined is kept as the
  sensor `:wifi_events`' current value.

  If `iw` is missing or exits, it tries again after a minute.
  """
  use GenServer
  require Logger
  alias Jantar.History

  @retry_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    History.declare({:event, :wifi}, 30 * 60_000)
    send(self(), :open)
    {:ok, %{port: nil, buffer: "", bssid: nil}}
  end

  @impl true
  def handle_info(:open, state) do
    case System.find_executable("iw") do
      nil ->
        Process.send_after(self(), :open, @retry_ms)
        {:noreply, state}

      iw ->
        port =
          Port.open({:spawn_executable, iw}, [
            :binary,
            :exit_status,
            {:line, 1024},
            args: ["event", "-t"]
          ])

        {:noreply, %{state | port: port}}
    end
  end

  def handle_info({port, {:data, {_eol, line}}}, %{port: port} = state) do
    now = System.monotonic_time(:millisecond)

    state =
      case :jantar_core@parse.iw_event(line) do
        {:ok, {iface, {:connected, bssid}}} ->
          History.push({:event, :wifi}, now, 1)
          History.put_sensor(:wifi_events, :ok, %{iface: iface, bssid: bssid}, now)
          %{state | bssid: bssid}

        {:ok, {_iface, {:disconnected, _reason}}} ->
          History.push({:event, :wifi}, now, -1)
          state

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("iw event exited (#{status}); retrying in #{div(@retry_ms, 1000)} s")
    Process.send_after(self(), :open, @retry_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
