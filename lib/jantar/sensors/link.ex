defmodule Jantar.Sensors.Link do
  @moduledoc """
  Whether the network link actually works, from two cheap file reads every
  2 s: is there a default route (`/proc/net/route`; it goes when a DHCP lease
  is lost), and has the gateway answered ARP (`/proc/net/arp`). No pings, so
  nothing leaves the machine and the service needs no IP sockets.

  And IPv6: a global address on the default route's interface
  (`/proc/net/if_inet6`) and an IPv6 default route (`/proc/net/ipv6_route`).

  Series `{:link, :route}`, `{:link, :gateway}` and `{:link, :ipv6}` (1 up,
  0 down, 30 min). Each change is also an event in `{:event, :link}` (`2`
  route back, `-2` route lost, `3` gateway back, `-3` gateway gone, `4` IPv6
  up, `-4` IPv6 gone), which the network dials draw as radial lines.
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
        {{:link, :ipv6}, 30 * 60_000},
        {{:event, :link}, 30 * 60_000}
      ]

      {:ok, %{root: opts[:root], route: nil, gateway: nil, ipv6: nil}, series}
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

    v6_iface =
      case :jantar_core@parse.ipv6_default_route(
             Sysfs.read_raw(state.root, "/proc/net/ipv6_route") || ""
           ) do
        {:ok, name} -> name
        {:error, _} -> nil
      end

    v6_up =
      v6_iface != nil and
        :jantar_core@parse.ipv6_global(
          Sysfs.read_raw(state.root, "/proc/net/if_inet6") || "",
          v6_iface
        )

    if state.ipv6 != nil and v6_up != state.ipv6,
      do: History.push({:event, :link}, now, if(v6_up, do: 4, else: -4))

    # A change from a known state is a cutover worth marking on the dials.
    if state.route != nil and route_up != state.route,
      do: History.push({:event, :link}, now, if(route_up, do: 2, else: -2))

    if state.gateway != nil and gw_up != state.gateway,
      do: History.push({:event, :link}, now, if(gw_up, do: 3, else: -3))

    readings = [
      {{:link, :route}, bit(route_up)},
      {{:link, :gateway}, bit(gw_up)},
      {{:link, :ipv6}, bit(v6_up)}
    ]

    current = %{route: route_up, gateway: gw_up, iface: iface, gateway_ip: gw, ipv6: v6_up}
    {:ok, readings, current, %{state | route: route_up, gateway: gw_up, ipv6: v6_up}}
  end

  defp bit(true), do: 1
  defp bit(false), do: 0
end
