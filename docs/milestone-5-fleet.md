# Milestone 5: fleet view

Watch several machines from one dashboard, including over slow or flaky links and
machines on networks I don't control. Builds on milestones 3–4 (renderers) and the VT12
service.

## Shape

- **Every machine runs the collector** (sensors + History), exactly as on this laptop.
  It keeps sampling while disconnected; History is the outage buffer.
- **Transport is MQTT, for every machine.** Some of the fleet is Raspberry Pis
  on other networks (BEAM apps built by me), so nothing may cross a trust boundary
  with Erlang distribution or Partisan: both let a connected node run code on the
  other, in both directions. MQTT carries data only. Distribution stays local
  (`iex --remsh` on one machine).
- **One viewer** (this laptop, VT12) subscribes and draws a grid of small dials,
  one cell per machine, each with a "last heard from" age that turns yellow/red.

## MQTT design

- **Broker:** Mosquitto on NixOS (`services.mosquitto`) on the tailnet, so every
  device only makes outbound connections (nothing to open on the remote
  network). VerneMQ/EMQX (both BEAM) are the upgrade path if it ever needs to grow.
- **Client library:** `emqtt` (MQTT 5, Erlang). On the Pis it is one more OTP app
  in their existing release (a custom BEAM app today, maybe Nerves someday): the
  collector + publisher, no renderer.
- **Collector as a pure-BEAM library** (`jantar_collector`: sensors, History,
  publisher; Gleam core compiled to `.beam`). No NIFs, so the same package runs
  on x86 and ARM unchanged and drops into a Nerves firmware later. The renderers
  stay in the viewer-only app.
- **Apps that already measure themselves:** a host app with its own health
  module only needs the publisher, fed from that module's snapshot (every 30 s
  is plenty over a poor uplink). The full 4 Hz collector is optional there.
  Pis that only run a browser get a tiny standalone collector release.
- **Local outbox:** `emqtt` doesn't queue while disconnected, so the publisher
  sends from History and only advances its "sent up to" mark on PUBACK. A flaky
  wifi uplink then costs latency, never data.
- **Metrics only, never application data:** for an app holding personal data,
  the publisher has a fixed allowlist of system fields. No database sizes, row
  counts or anything derived from them.
- **Pi sensors:** `thermal_zone0`, CPU frequency, and the firmware's throttle and
  under-voltage flags (`get_throttled`), the usual cause of flaky Pis. Disk
  usage/writes too, for SD-card wear.
- **Topics:** `hud/<site>/<host>/batch` (samples), `hud/<site>/<host>/status`
  (retained `online` / Last Will `offline`, so a dead link shows immediately).
- **Payload:** a batch of samples every 1–5 s, per-link interval, compressed with
  zstd (OTP 28 `:zstd`). Never `binary_to_term` on data from a machine I don't
  control. Format: columnar, each sensor quantised to an integer (CPU in 0.1 %,
  others in hundredths) and delta-encoded, laid out as **protobuf wire format**:
  base timestamp, then one packed `repeated sint32` field per column (zigzag
  varints, so small deltas take one byte). A `.proto` file documents it, so any
  language can decode it; on the BEAM it is written and parsed with bit syntax
  (~20 lines, zero dependencies), or with the `protobuf` Hex package if that is
  simpler. The MQTT 5 content-type property carries the schema version.

  Measured, one minute = 240 samples of 16 CPU cores + 10 sensors (random-walk
  data, so real, flatter readings compress better):

  | format                    |    raw |   zstd |
  |---------------------------|-------:|-------:|
  | JSON, row per sample      | 60 KB  | 16 KB  |
  | Erlang term, rows         | 77 KB  | 19 KB  |
  | JSON, columnar            | 40 KB  | 12 KB  |
  | float32 columns           | 25 KB  | 15 KB  |
  | quantised + delta, int16  | 13 KB  |  7 KB  |
  | protobuf, packed sint32   |  7 KB  | 5.4 KB |

  Raw floats compress badly (noisy mantissa bits); quantising is what wins, and
  varints beat fixed int16 because most deltas are tiny. zstd takes ~20 µs a batch.
- **High latency / outages:** QoS 1, persistent sessions (`clean_start false`,
  session expiry of hours) so the broker queues while the viewer sleeps;
  MQTT 5 message expiry so stale batches don't pile up forever. Gaps longer than
  the queue are backfilled on request (`hud/<site>/<host>/backfill` with a
  `since` timestamp, answered from that host's History).

## Security

1. **Network: Tailscale for remote Pis, WireGuard for my own machines** (or
   Tailscale for all; it is WireGuard underneath). Remote Pis get a tag
   (`tag:jantar-<site>`) and the tailnet policy lets that tag reach **only the broker
   port**, nothing else on my laptop or tailnet. Mosquitto listens on the tailnet
   address only.
2. **Broker auth:** one username + password (or token) per device; ACL
   `pattern write hud/+/%u/#` so each device can publish only under its own name
   and read nothing. The viewer is the only reader.
3. **TLS:** Mosquitto on 8883 with a Let's Encrypt certificate via NixOS
   `security.acme` (DNS-01, so the broker host needn't be publicly reachable).
   Server identity only: Let's Encrypt stopped issuing client-auth certificates
   in 2026 (the `tlsclient` profile ended 8 July 2026), so clients authenticate
   with their credentials and their tailnet identity, not certificates.
4. **Consent:** agree with whoever runs a network what leaves it
   (system metrics only: CPU, memory, temperature, disk, link), and keep a
   per-site switch that turns publishing off.
5. **Optional public page:** an HTTPS fleet page (e.g. Phoenix LiveView) on the
   same Let's Encrypt certificate, with its own login.

Remote collectors run as an unprivileged user; only the viewer needs `video`.

## Steps

1. Collector-only mode (no renderer) and `Jantar.Fleet.Publisher` /
   `Jantar.Fleet.Viewer` against a local Mosquitto, with two nodes on this laptop.
2. Viewer grid layout in both renderers; staleness colours; Last Will handling.
3. Outage test: stop the viewer, then delay the link with tc/netem, and check that
   queued and backfilled data fill the gap.
4. NixOS module options: broker, ACLs, per-device credentials (agenix or
   sops-nix, never in git), Let's Encrypt, tailnet-only listener.
5. First remote: my other laptop. Then one remote Pi as a pilot, once its
   network's owner agrees.
6. Optional: LiveView page.
