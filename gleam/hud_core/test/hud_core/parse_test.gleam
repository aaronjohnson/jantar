//// Parsers against recorded files from this machine (test/fixtures/capture)
//// and small hand-written cases for the corners. Expected values marked
//// "hud:" come from tools/hud_oracle.py, i.e. the Python hud's own code.

import gleam/int
import gleam/list
import hud_core/fixture
import hud_core/parse.{CpuTimes, Interface, Link, MemInfo, Progress}

// ------------------------------------------------------------------ helpers

pub fn number_test() {
  assert parse.number("42\n") == Ok(42.0)
  assert parse.number(" -3 ") == Ok(-3.0)
  assert parse.number("5180.0") == Ok(5180.0)
  assert parse.number("") == Error(Nil)
  assert parse.number("abc") == Error(Nil)
  assert parse.integer("1950\n") == Ok(1950)
}

pub fn fields_test() {
  assert parse.fields("cpu  12\t34 ") == ["cpu", "12", "34"]
}

// ------------------------------------------------------------------ /proc/stat

pub fn cpu_times_small_test() {
  let text =
    "cpu  10 1 5 100 4 2 3 0 7 0\ncpu0 10 1 5 100 4 2 3 0 7 0\nintr 1 2 3\ncpu9 1 1 1 1\n"
  // busy = user+nice+system+irq+softirq+steal; guest (7) is not counted again.
  assert parse.cpu_times(text)
    == [CpuTimes(busy: 21, total: 125), CpuTimes(busy: 21, total: 125)]
  // Lines after the first non-cpu line are ignored, like hud.
  assert parse.cpu_ids(text) == [0]
}

pub fn cpu_times_capture_test() {
  let times = parse.cpu_times(fixture.read("t0", "/proc/stat"))
  // The aggregate plus 16 cpus on this machine.
  assert list.length(times) == 17
  assert parse.cpu_ids(fixture.read("t0", "/proc/stat"))
    == int.range(from: 15, to: -1, with: [], run: list.prepend)
}

pub fn cpu_list_test() {
  assert parse.cpu_list("0-3\n") == [0, 1, 2, 3]
  assert parse.cpu_list("0-1,4,6-7") == [0, 1, 4, 6, 7]
  assert parse.cpu_list("") == []
  assert parse.cpu_list("x,2") == [2]
  assert parse.cpu_list(fixture.read("t0", "/sys/devices/cpu_core/cpus"))
    == [0, 1, 2, 3]
}

// ------------------------------------------------------------------ /proc/meminfo

pub fn meminfo_capture_test() {
  let assert Ok(m) = parse.meminfo(fixture.read("t1", "/proc/meminfo"))
  // hud: mem_total_kb 65309752, used share 0.06200427770725572
  assert m.total == 65_309_752
  assert fixture.close(parse.mem_used_fraction(m), 0.06200427770725572)
}

pub fn meminfo_missing_total_test() {
  assert parse.meminfo("MemFree: 5 kB\n") == Error(Nil)
  assert parse.meminfo("") == Error(Nil)
  // Missing fields read as 0, like hud's info.get(..., 0).
  assert parse.meminfo("MemTotal: 100 kB\n")
    == Ok(MemInfo(total: 100, available: 0, swap_total: 0, swap_free: 0))
}

// ------------------------------------------------------------------ /proc/net/dev

pub fn net_dev_test() {
  let text =
    "Inter-|   Receive\n face |bytes\n    lo:  100 1 0 0 0 0 0 0  100 1 0 0 0 0 0 0\n"
    <> "wlan0: 2000 5 0 0 0 0 0 0 300 4 0 0 0 0 0 0\n"
    <> "eth0:7 1 0 0 0 0 0 0 11 1 0 0 0 0 0 0\n"
  let ifs = parse.net_dev(text)
  assert ifs
    == [
      Interface("lo", 100, 100),
      Interface("wlan0", 2000, 300),
      // No space after the colon: large counters can run into the name.
      Interface("eth0", 7, 11),
    ]
  assert parse.net_totals(ifs) == #(2007, 311)
}

pub fn net_dev_capture_test() {
  // hud: rx_total 2808987602, tx_total 762615367 (at t1)
  let totals =
    parse.net_totals(parse.net_dev(fixture.read("t1", "/proc/net/dev")))
  assert totals == #(2_808_987_602, 762_615_367)
}

// ------------------------------------------------------------------ processes

pub fn uptime_test() {
  assert parse.uptime("70874.63 199507.48\n") == Ok(70_874.63)
  assert parse.uptime("") == Error(Nil)
}

pub fn proc_start_ticks_test() {
  // The command name may contain spaces and ")"; count from the last ")".
  let stat =
    "1234 (Runner.Worker (x)) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 20 21\n"
  assert parse.proc_start_ticks(stat) == Ok(987_654)
  assert parse.proc_start_ticks("garbage") == Error(Nil)
}

pub fn cgroup_test() {
  assert parse.cgroup_populated("populated 1\nfrozen 0\n")
  assert !parse.cgroup_populated("populated 0\nfrozen 0\n")
  assert !parse.cgroup_populated("")
  assert parse.pids("12\n34\n") == [12, 34]
}

// ------------------------------------------------------------------ CI progress

pub fn ci_progress_test() {
  assert parse.ci_progress("llvm 120 4000\n")
    == Ok(Progress("llvm", 120.0, 4000.0))
  assert parse.ci_progress("llvm 1.5 3") == Ok(Progress("llvm", 1.5, 3.0))
  // Not three fields, or no total: no progress (hud clears the bar).
  assert parse.ci_progress("llvm 120") == Error(Nil)
  assert parse.ci_progress("llvm 120 0") == Error(Nil)
  assert parse.ci_progress("a b c d") == Error(Nil)
  assert parse.ci_progress("") == Error(Nil)
}

// ------------------------------------------------------------------ wifi

pub fn nmcli_test() {
  assert parse.nmcli(" :80:Other\n*:63:Home\\:Net\n") == #(63, "Home:Net")
  assert parse.nmcli(" :80:Other\n") == #(-1, "")
  // An SSID can be empty (hidden network).
  assert parse.nmcli("*:40:\n") == #(40, "")
}

pub fn iw_single_link_test() {
  let text =
    "Interface wlan0\n\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz\n"
    <> "Connected to 02:00:00:00:00:01 (on wlan0)\n\tfreq: 5180\n"
    <> "\tsignal: -61 dBm\n\ttx bitrate: 866.7 MBit/s VHT-MCS 9\n"
  // No "Link N" lines: a plain link 0, active because it is the only one.
  assert parse.iw(text) == #([Link(0, 5180, True)], 80, -61, 866.7)
}

pub fn iw_disconnected_test() {
  assert parse.iw("Interface wlan0\n\ttype managed\nNot connected.\n")
    == #([], 0, 0, 0.0)
}

pub fn wifi_capture_test() {
  // hud: signal 63, ssid Network-4, links [[1, 5180, false], [2, 6375, true]],
  // width 320, dbm -57, bitrate 1152.9 (MLO: the channel line belongs to link 2)
  let w = parse.wifi(fixture.read("t1", "/wifi.txt"))
  assert w.ok
  assert w.signal == 63
  assert w.ssid == "Network-4"
  assert w.links == [Link(1, 5180, False), Link(2, 6375, True)]
  assert w.width_mhz == 320
  assert w.dbm == -57
  assert w.bitrate_mbit == 1152.9
}

pub fn wifi_empty_test() {
  // The command failed: not ok (hud hides the dial).
  let w = parse.wifi("")
  assert !w.ok
  assert w.signal == -1
}
