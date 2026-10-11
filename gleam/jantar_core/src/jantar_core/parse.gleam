//// Parsers for the text that Linux exposes in /proc and /sys, and for the
//// output of the wifi tools. Every function here takes a String (the file's
//// contents) and returns typed data: no file access, so each one can be tested
//// with recorded samples.
////
//// The semantics follow ~/dotfiles/bin/hud (the Python reference) exactly; the
//// comments name the hud method each parser stands in for.

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ------------------------------------------------------------------ helpers

/// Split text into whitespace-separated fields, like Python's str.split():
/// "cpu  12\t34\n" -> ["cpu", "12", "34"].
pub fn fields(line: String) -> List(String) {
  line
  |> string.replace("\t", " ")
  |> string.replace("\n", " ")
  |> string.split(" ")
  |> list.filter(fn(s) { s != "" })
}

/// A number as sysfs writes it: "42", "-3", "5180.0", with surrounding
/// whitespace. Gleam's float.parse wants a decimal point, so try Int first.
pub fn number(text: String) -> Result(Float, Nil) {
  let t = string.trim(text)
  case int.parse(t) {
    Ok(i) -> Ok(int.to_float(i))
    Error(_) -> float.parse(t)
  }
}

/// An integer, accepting "1.0"-style floats too (truncated), like int(float(s)).
pub fn integer(text: String) -> Result(Int, Nil) {
  number(text) |> result.map(float.truncate)
}

fn lines(text: String) -> List(String) {
  string.split(text, "\n")
}

// ------------------------------------------------------------------ /proc/stat

/// Jiffies for one line of /proc/stat: busy = everything but idle and iowait.
pub type CpuTimes {
  CpuTimes(busy: Int, total: Int)
}

/// The "cpu" lines of /proc/stat, in order: the aggregate first, then cpu0,
/// cpu1, ... Stops at the first line that isn't a cpu line (hud's read_cpu).
pub fn cpu_times(text: String) -> List(CpuTimes) {
  text
  |> lines
  |> list.take_while(fn(l) { string.starts_with(l, "cpu") })
  |> list.map(fn(line) {
    // user nice system idle iowait irq softirq steal; guest is inside user.
    let values =
      fields(line)
      |> list.drop(1)
      |> list.take(8)
      |> list.map(fn(s) { int.parse(s) |> result.unwrap(0) })
    let total = int.sum(values)
    let idle = values |> list.drop(3) |> list.take(2) |> int.sum
    CpuTimes(busy: total - idle, total: total)
  })
}

/// The cpu numbers in /proc/stat ("cpu3" -> 3), skipping the aggregate line.
pub fn cpu_ids(text: String) -> List(Int) {
  text
  |> lines
  |> list.drop(1)
  |> list.take_while(fn(l) { string.starts_with(l, "cpu") })
  |> list.filter_map(fn(line) {
    case fields(line) {
      [name, ..] -> int.parse(string.drop_start(name, 3))
      [] -> Error(Nil)
    }
  })
}

/// A cpu list as in /sys/devices/cpu_core/cpus: "0-3,8,10-11" -> [0,1,2,3,8,10,11].
pub fn cpu_list(text: String) -> List(Int) {
  text
  |> string.trim
  |> string.split(",")
  |> list.flat_map(fn(part) {
    case string.split_once(string.trim(part), "-") {
      Ok(#(a, b)) ->
        case int.parse(a), int.parse(b) {
          Ok(a), Ok(b) if a <= b ->
            int.range(from: a, to: b + 1, with: [], run: list.prepend)
            |> list.reverse
          _, _ -> []
        }
      Error(_) ->
        case int.parse(string.trim(part)) {
          Ok(n) -> [n]
          Error(_) -> []
        }
    }
  })
}

// ------------------------------------------------------------------ /proc/meminfo

/// The /proc/meminfo fields hud uses, in kB.
pub type MemInfo {
  MemInfo(total: Int, available: Int, swap_total: Int, swap_free: Int)
}

/// Error if MemTotal is missing or zero (hud then keeps its previous reading).
pub fn meminfo(text: String) -> Result(MemInfo, Nil) {
  let values =
    text
    |> lines
    |> list.filter_map(fn(line) {
      use #(key, rest) <- result.try(string.split_once(line, ":"))
      use first <- result.try(list.first(fields(rest)))
      use n <- result.map(int.parse(first))
      #(key, n)
    })
    |> dict.from_list
  let get = fn(key) { dict.get(values, key) |> result.unwrap(0) }
  case get("MemTotal") {
    0 -> Error(Nil)
    total ->
      Ok(MemInfo(
        total: total,
        available: get("MemAvailable"),
        swap_total: get("SwapTotal"),
        swap_free: get("SwapFree"),
      ))
  }
}

/// Share of memory in use, 0..1: (MemTotal - MemAvailable) / MemTotal.
pub fn mem_used_fraction(m: MemInfo) -> Float {
  int.to_float(m.total - m.available) /. int.to_float(m.total)
}

// ------------------------------------------------------------------ /proc/net/dev

pub type Interface {
  Interface(name: String, rx_bytes: Int, tx_bytes: Int)
}

/// Every interface in /proc/net/dev (after the two header lines).
pub fn net_dev(text: String) -> List(Interface) {
  text
  |> lines
  |> list.drop(2)
  |> list.filter_map(fn(line) {
    use #(name, rest) <- result.try(string.split_once(line, ":"))
    case fields(rest) {
      [rx, _, _, _, _, _, _, _, tx, ..] -> {
        use rx <- result.try(int.parse(rx))
        use tx <- result.map(int.parse(tx))
        Interface(name: string.trim(name), rx_bytes: rx, tx_bytes: tx)
      }
      _ -> Error(Nil)
    }
  })
}

/// Bytes received and sent since boot over every interface except loopback.
pub fn net_totals(interfaces: List(Interface)) -> #(Int, Int) {
  interfaces
  |> list.filter(fn(i) { i.name != "lo" })
  |> list.fold(#(0, 0), fn(acc, i) { #(acc.0 + i.rx_bytes, acc.1 + i.tx_bytes) })
}

// ------------------------------------------------------------------ processes and cgroups

/// Seconds since boot, the first field of /proc/uptime.
pub fn uptime(text: String) -> Result(Float, Nil) {
  text |> fields |> list.first |> result.try(number)
}

/// A process's start time in clock ticks after boot: field 22 of
/// /proc/<pid>/stat. The command name (field 2) is in parentheses and may hold
/// spaces or ")", so count fields from the last ")".
pub fn proc_start_ticks(stat: String) -> Result(Int, Nil) {
  let after_name =
    string.split(stat, ")")
    |> list.last
    |> result.unwrap("")
  // after_name starts at field 3 (state), so starttime (22) is index 19.
  after_name
  |> fields
  |> list.drop(19)
  |> list.first
  |> result.try(int.parse)
}

/// Whether a cgroup has processes in it ("populated 1" in cgroup.events).
pub fn cgroup_populated(events: String) -> Bool {
  events |> lines |> list.any(fn(l) { string.trim(l) == "populated 1" })
}

/// The pids in a cgroup.procs file.
pub fn pids(text: String) -> List(Int) {
  text |> fields |> list.filter_map(int.parse)
}

// ------------------------------------------------------------------ CI status

/// The runner's build progress file: "<package> <done> <total>".
pub type Progress {
  Progress(package: String, done: Float, total: Float)
}

/// Error unless the line has exactly three fields and a positive total.
pub fn ci_progress(text: String) -> Result(Progress, Nil) {
  case fields(string.trim(text)) {
    [package, done, total] -> {
      use done <- result.try(number(done))
      use total <- result.try(number(total))
      case total >. 0.0 {
        True -> Ok(Progress(package, done, total))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

// ------------------------------------------------------------------ wifi

/// One wifi link: with multi-link operation (wifi 7) there can be several.
pub type Link {
  Link(id: Int, freq_mhz: Int, active: Bool)
}

/// What hud shows for wifi. `ok` is False when the command produced nothing;
/// `signal` is -1 when not connected.
pub type Wifi {
  Wifi(
    ok: Bool,
    signal: Int,
    ssid: String,
    links: List(Link),
    width_mhz: Int,
    dbm: Int,
    bitrate_mbit: Float,
  )
}

/// The in-use network from `nmcli -t -f IN-USE,SIGNAL,SSID device wifi list`:
/// #(signal 0..100, ssid), or #(-1, "") if none is marked "*".
pub fn nmcli(text: String) -> #(Int, String) {
  let in_use = text |> lines |> list.find(fn(l) { string.starts_with(l, "*:") })
  case in_use {
    Error(_) -> #(-1, "")
    Ok(line) -> {
      let #(signal, ssid) =
        string.split_once(string.drop_start(line, 2), ":")
        |> result.unwrap(#(string.drop_start(line, 2), ""))
      // nmcli -t escapes ":" inside fields as "\:".
      #(
        int.parse(signal) |> result.unwrap(-1),
        string.replace(ssid, "\\:", ":"),
      )
    }
  }
}

/// The text after `marker` in `line`, if present.
fn after(line: String, marker: String) -> Option(String) {
  case string.split_once(line, marker) {
    Ok(#(_, rest)) -> Some(rest)
    Error(_) -> None
  }
}

/// The leading run of characters in `text` that satisfy `keep`.
fn leading(text: String, keep: fn(String) -> Bool) -> String {
  text
  |> string.to_graphemes
  |> list.take_while(keep)
  |> string.concat
}

fn is_digit(c: String) -> Bool {
  string.contains("0123456789", c) && c != ""
}

fn leading_int(text: String) -> Result(Int, Nil) {
  int.parse(leading(text, is_digit))
}

/// State threaded through the lines of `iw dev <if> info` + `iw dev <if> link`.
type IwScan {
  IwScan(
    info_link: Int,
    link_link: Int,
    active: Int,
    // Links in first-seen order, newest first (reversed at the end).
    links: List(#(Int, Int)),
    width: Int,
    dbm: Int,
    bitrate: Float,
  )
}

/// Parse `iw dev <if> info` and `iw dev <if> link`: `info` lists the MLO links
/// and gives a channel only for the active one; `link` gives each link's
/// frequency. No "Link N" lines means a plain single link, id 0.
/// Returns #(links, width MHz, signal dBm, tx bitrate MBit/s); 0 when absent.
pub fn iw(text: String) -> #(List(Link), Int, Int, Float) {
  let start = IwScan(-1, 0, -1, [], 0, 0, 0.0)
  let s = list.fold(lines(text), start, iw_line)
  let order = list.reverse(s.links)
  let active = case order {
    [#(only, _)] -> only
    _ -> s.active
  }
  let links =
    list.map(order, fn(l) {
      Link(id: l.0, freq_mhz: l.1, active: l.0 == active)
    })
  #(links, s.width, s.dbm, s.bitrate)
}

fn iw_line(s: IwScan, line: String) -> IwScan {
  let trimmed = string.trim_start(line)
  // Each case mirrors one regular expression in hud's take_wifi, tried in order.
  case after(line, "- link ID") {
    Some(rest) ->
      case leading_int(string.trim_start(rest)) {
        Ok(id) -> IwScan(..s, info_link: id)
        Error(_) -> s
      }
    None ->
      case channel_width(line) {
        Ok(width) ->
          IwScan(..s, width: width, active: case s.info_link >= 0 {
            True -> s.info_link
            False -> 0
          })
        Error(_) ->
          case link_bssid(line) {
            Ok(id) -> IwScan(..s, link_link: id)
            Error(_) ->
              case string.starts_with(trimmed, "freq: ") {
                True -> iw_freq(s, string.drop_start(trimmed, 6))
                False -> iw_signal_or_bitrate(s, trimmed, line)
              }
          }
      }
  }
}

/// "channel 85 (6375 MHz), width: 320 MHz, ..." -> 320
fn channel_width(line: String) -> Result(Int, Nil) {
  use rest <- result.try(option.to_result(after(line, "channel "), Nil))
  use #(_, rest) <- result.try(string.split_once(rest, " MHz), width: "))
  use #(width, _) <- result.try(string.split_once(rest, " MHz"))
  int.parse(width)
}

/// "Link 2 BSSID ..." -> 2
fn link_bssid(line: String) -> Result(Int, Nil) {
  use rest <- result.try(option.to_result(after(line, "Link "), Nil))
  use #(id, rest) <- result.try(string.split_once(rest, " "))
  case string.starts_with(rest, "BSSID") {
    True -> int.parse(id)
    False -> Error(Nil)
  }
}

fn iw_freq(s: IwScan, rest: String) -> IwScan {
  let text = leading(rest, fn(c) { is_digit(c) || c == "." })
  case number(text) {
    Error(_) -> s
    Ok(f) -> {
      let mhz = float.round(f)
      let id = s.link_link
      // Keep first-seen order; a repeated link id just updates its frequency.
      let links = case list.any(s.links, fn(l) { l.0 == id }) {
        True ->
          list.map(s.links, fn(l) {
            case l.0 == id {
              True -> #(id, mhz)
              False -> l
            }
          })
        False -> [#(id, mhz), ..s.links]
      }
      IwScan(..s, links: links)
    }
  }
}

fn iw_signal_or_bitrate(s: IwScan, trimmed: String, line: String) -> IwScan {
  case string.starts_with(trimmed, "signal: ") {
    True -> {
      let rest = string.drop_start(trimmed, 8)
      let text = case string.starts_with(rest, "-") {
        True -> "-" <> leading(string.drop_start(rest, 1), is_digit)
        False -> leading(rest, is_digit)
      }
      let unit = string.drop_start(rest, string.length(text))
      case int.parse(text), string.starts_with(unit, " dBm") {
        Ok(dbm), True -> IwScan(..s, dbm: dbm)
        _, _ -> s
      }
    }
    False ->
      case after(line, "tx bitrate: ") {
        Some(rest) -> {
          let text = leading(rest, fn(c) { is_digit(c) || c == "." })
          let unit = string.drop_start(rest, string.length(text))
          case number(text), string.starts_with(unit, " MBit") {
            Ok(rate), True -> IwScan(..s, bitrate: rate)
            _, _ -> s
          }
        }
        None -> s
      }
  }
}

/// The whole output of hud's wifi command: nmcli, a line "@@IW", then iw.
pub fn wifi(text: String) -> Wifi {
  let #(nm, iw_text) = case string.split_once(text, "@@IW") {
    Ok(parts) -> parts
    Error(_) -> #(text, "")
  }
  let #(signal, ssid) = nmcli(nm)
  let #(links, width, dbm, bitrate) = iw(iw_text)
  Wifi(
    ok: text != "",
    signal: signal,
    ssid: ssid,
    links: links,
    width_mhz: width,
    dbm: dbm,
    bitrate_mbit: bitrate,
  )
}
