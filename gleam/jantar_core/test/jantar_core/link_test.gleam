import gleeunit/should
import jantar_core/parse.{Connected, Disconnected, OtherEvent}

const route =
  "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
wlp0s20f3\t000200C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0
wlp0s20f3\t00000000\t010200C0\t0003\t0\t0\t600\t00000000\t0\t0\t0
"

const arp =
  "IP address       HW type     Flags       HW address            Mask     Device
192.0.2.9     0x1         0x2         00:00:5e:00:53:21     *        wlp0s20f3
192.0.2.1     0x1         0x2         00:00:5e:00:53:22     *        wlp0s20f3
192.0.2.7     0x1         0x0         00:00:00:00:00:00     *        wlp0s20f3
"

pub fn default_route_test() {
  parse.default_route(route) |> should.equal(Ok(#("wlp0s20f3", "192.0.2.1")))
}

pub fn no_default_route_test() {
  parse.default_route("Iface\tDestination\n") |> should.equal(Error(Nil))
}

pub fn arp_test() {
  parse.arp_reachable(arp, "192.0.2.1") |> should.be_true
  // Flags 0x0: an incomplete entry, it never answered.
  parse.arp_reachable(arp, "192.0.2.7") |> should.be_false
  parse.arp_reachable(arp, "198.51.100.1") |> should.be_false
}

pub fn iw_event_test() {
  parse.iw_event(
    "1791692363.36: wlp0s20f3 (phy #0): connected to 00:00:5e:00:53:0a",
  )
  |> should.equal(Ok(#("wlp0s20f3", Connected("00:00:5e:00:53:0a"))))
  parse.iw_event(
    "1791692363.36: wlp0s20f3 (phy #0): disconnected (by local request) reason: 3",
  )
  |> should.equal(
    Ok(#("wlp0s20f3", Disconnected("(by local request) reason: 3"))),
  )
  parse.iw_event("1791692363.36: wlp0s20f3 (phy #0): scan started")
  |> should.equal(Ok(#("wlp0s20f3", OtherEvent)))
  parse.iw_event("garbage") |> should.equal(Error(Nil))
}

const if_inet6 =
  "00000000000000000000000000000001 01 80 10 80       lo
fe80000000000000398084ed9d14a5fa 02 40 20 80 wlp0s20f3
"

const if_inet6_global =
  "fe80000000000000398084ed9d14a5fa 02 40 20 80 wlp0s20f3
2001db8000000000398084ed9d14a5fa 02 40 00 00 wlp0s20f3
"

const ipv6_route_none =
  "00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 ffffffff 00000001 00000000 00200200       lo
"

const ipv6_route =
  "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003 wlp0s20f3
00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 ffffffff 00000001 00000000 00200200       lo
"

pub fn ipv6_global_test() {
  parse.ipv6_global(if_inet6, "wlp0s20f3") |> should.be_false
  parse.ipv6_global(if_inet6_global, "wlp0s20f3") |> should.be_true
}

pub fn ipv6_default_route_test() {
  // Only lo's reject route: no IPv6 default.
  parse.ipv6_default_route(ipv6_route_none) |> should.equal(Error(Nil))
  parse.ipv6_default_route(ipv6_route) |> should.equal(Ok("wlp0s20f3"))
}
