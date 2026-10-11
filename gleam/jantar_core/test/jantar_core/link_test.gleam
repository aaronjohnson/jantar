import gleeunit/should
import jantar_core/parse.{Connected, Disconnected, OtherEvent}

const route =
  "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
wlp0s20f3\t0058A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0
wlp0s20f3\t00000000\t0158A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0
"

const arp =
  "IP address       HW type     Flags       HW address            Mask     Device
192.168.88.9     0x1         0x2         aa:bb:cc:dd:ee:01     *        wlp0s20f3
192.168.88.1     0x1         0x2         aa:bb:cc:dd:ee:02     *        wlp0s20f3
192.168.88.7     0x1         0x0         00:00:00:00:00:00     *        wlp0s20f3
"

pub fn default_route_test() {
  parse.default_route(route) |> should.equal(Ok(#("wlp0s20f3", "192.168.88.1")))
}

pub fn no_default_route_test() {
  parse.default_route("Iface\tDestination\n") |> should.equal(Error(Nil))
}

pub fn arp_test() {
  parse.arp_reachable(arp, "192.168.88.1") |> should.be_true
  // Flags 0x0: an incomplete entry, it never answered.
  parse.arp_reachable(arp, "192.168.88.7") |> should.be_false
  parse.arp_reachable(arp, "10.0.0.1") |> should.be_false
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
