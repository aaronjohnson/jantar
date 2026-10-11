#!/usr/bin/env bash
# Snapshot the files jantar reads into test/fixtures/capture/{t0,t1}, two
# seconds apart, laid out like the real root (proc/stat, sys/class/...), so the
# sensors can be pointed at them with `root:` and rates can be computed.
#
#   tools/capture-fixtures.sh [out-dir]      (default: test/fixtures/capture)
#
# Only small text files are copied. MAC addresses and SSIDs are anonymised.
set -euo pipefail
out=${1:-test/fixtures/capture}
unit=github-runner-nixos-intel-npu.service

copy() {                     # copy each readable file to $dst/<its absolute path>
  for f in "$@"; do
    [ -r "$f" ] && [ -f "$f" ] || continue
    mkdir -p "$dst$(dirname "$f")"
    cat "$f" > "$dst$f" 2>/dev/null || rm -f "$dst$f"
  done
}

anonymise() {                # MACs -> 02:00:00:00:00:NN, SSIDs -> Network-N
  awk '
    function mac(m) { if (!(m in macs)) macs[m] = sprintf("02:00:00:00:00:%02x", ++nm); return macs[m] }
    function net(s) { if (!(s in nets)) nets[s] = "Network-" (++nn); return nets[s] }
    {
      out = ""; rest = $0          # scan left to right so a replaced MAC is never rescanned
      while (match(rest, /([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]/)) {
        out = out substr(rest, 1, RSTART - 1) mac(substr(rest, RSTART, RLENGTH))
        rest = substr(rest, RSTART + RLENGTH)
      }
      $0 = out rest
      if (!seen_iw && $0 ~ /^[ *]:[0-9]+:/) {          # nmcli -t: IN-USE:SIGNAL:SSID
        p = index(substr($0, 3), ":") + 2
        $0 = substr($0, 1, p) net(substr($0, p + 1))
      } else if ($0 ~ /^@@IW/) {
        seen_iw = 1
      } else if (match($0, /(ssid |SSID: )/)) {
        k = RSTART + RLENGTH
        $0 = substr($0, 1, k - 1) net(substr($0, k))
      }
      print
    }'
}

snapshot() {
  dst=$out/$1
  rm -rf "$dst"; mkdir -p "$dst"
  copy /proc/stat /proc/meminfo /proc/net/dev /proc/uptime
  for d in /sys/class/hwmon/hwmon*; do
    copy "$d"/name "$d"/temp*_label "$d"/temp*_input "$d"/fan1_input
  done
  copy /sys/devices/system/cpu/cpu[0-9]*/cpufreq/{cpuinfo_max_freq,scaling_cur_freq} /sys/devices/cpu_core/cpus
  # drm: card0/device is a symlink in sysfs; keep it one, pointing at a copied device dir.
  for c in /sys/class/drm/card[0-9]; do
    dev=$(realpath "$c/device")
    mkdir -p "$dst$c"; ln -sfn "../../..${dev#/sys}" "$dst$c/device"
    mkdir -p "$dst$dev"; ln -sfn "../../../bus/pci/drivers/$(basename "$(realpath "$dev/driver")")" "$dst$dev/driver"
    copy "$dev"/tile*/gt*/gtidle/{name,idle_residency_ms} "$dev"/tile*/gt*/freq0/{act_freq,max_freq}
  done
  copy /sys/class/power_supply/BAT*/{status,capacity,current_now,voltage_now,charge_now,charge_full}
  copy /sys/class/power_supply/ucsi-source-psy-*/{online,voltage_now,current_max}
  npu=/sys/class/accel/accel0/device
  copy $npu/npu_{busy_time_us,current_frequency_mhz,max_frequency_mhz,memory_utilization} $npu/power/runtime_status
  # The CI runner: unit file (presence only), cgroup, its processes, ci-status.
  if [ -e /etc/systemd/system/$unit ]; then mkdir -p "$dst/etc/systemd/system"; : > "$dst/etc/systemd/system/$unit"; fi
  cg=/sys/fs/cgroup/system.slice/$unit
  copy $cg/cgroup.events $cg/cgroup.procs /run/github-runner/nixos-intel-npu/ci-status/{step,progress}
  for pid in $(cat $cg/cgroup.procs 2>/dev/null); do copy /proc/$pid/cmdline /proc/$pid/stat; done
  # wifi: the same command hud runs, as text.
  { nmcli -t -f IN-USE,SIGNAL,SSID device wifi list --rescan no; echo @@IW
    command -v iw >/dev/null && for i in $(iw dev | awk '/Interface/{print $2}'); do
      iw dev "$i" info; iw dev "$i" link; done; } 2>/dev/null | anonymise > "$dst/wifi.txt" || true
}

snapshot t0
sleep 2
snapshot t1
echo "captured into $out/{t0,t1}"
