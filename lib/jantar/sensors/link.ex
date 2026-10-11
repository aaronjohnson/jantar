defmodule Jantar.Sensors.Link do
  @moduledoc """
  Whether the network link actually works, from two cheap file reads every
  2 s: is there a default route (`/proc/net/route`; it goes when a DHCP lease
  is lost), and has the gateway answered ARP (`/proc/net/arp`). No pings, so
  nothing leaves the machine and the service needs no IP sockets.

  Series `{:link, :route}` and `{:link, :gateway}` (1 up, 0 down, 30 min).
  Each change is also an event in `{:event, :link}` (`2` route back, `-2`
  route lost, `3` gateway back, `-3` gateway gone), which the network dials
  draw as radial lines.
  """
  @behaviour Jantar.Sensor
  alias Jantar.{History, Sysfs}

  @impl true
  def defaults, do: [interval: 2_000]

  @impl true
  def init(opts) do
    if Sysfs.exists?(opts[:root], "/proc/net/route") do
      series = [
        {{:link, :route}, 30 * 60_000},
        {{:link, :gateway}, 30 * 60_000},
        {{:event, :link}, 30 * 60_000}
      ]

      {:ok, %{root: opts[:root], route: nil, gateway: nil}, series}
    else
      {:unavailable, :no_proc_net_route}
    end
  end

  @impl true
  def sample(state, now) do
    route = :jantar_core@parse.default_route(Sysfs.read_raw(state.root, "/proc/net/route") || "")

    {iface, gw, route_up} =
      case route do
        {:ok, {iface, gw}} -> {iface, gw, true}
        {:error, _} -> {nil, nil, false}
      end

    gw_up =
      route_up and
        :jantar_core@parse.arp_reachable(Sysfs.read_raw(state.root, "/proc/net/arp") || "", gw)

    # A change from a known state is a cutover worth marking on the dials.
    if state.route != nil and route_up != state.route,
      do: History.push({:event, :link}, now, if(route_up, do: 2, else: -2))

    if state.gateway != nil and gw_up != state.gateway,
      do: History.push({:event, :link}, now, if(gw_up, do: 3, else: -3))

    readings = [{{:link, :route}, bit(route_up)}, {{:link, :gateway}, bit(gw_up)}]
    current = %{route: route_up, gateway: gw_up, iface: iface, gateway_ip: gw}
    {:ok, readings, current, %{state | route: route_up, gateway: gw_up}}
  end

  defp bit(true), do: 1
  defp bit(false), do: 0
end
