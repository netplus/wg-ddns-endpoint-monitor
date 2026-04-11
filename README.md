# wg-ddns-endpoint-monitor

`wg-ddns-endpoint-monitor` is a lightweight Bash monitor for the WireGuard case where a peer uses `Endpoint=hostname:port` and the hostname later resolves to a different IP.

It runs as a `systemd` timer-driven oneshot service, checks WireGuard runtime state, resolves the configured hostname only when necessary, and refreshes the runtime endpoint with `wg set`.

Configuration changes can also trigger an immediate run through a lightweight `systemd.path` unit that watches the two managed config files.

## What It Solves

WireGuard accepts hostname endpoints in configuration, but its runtime peer endpoint is still a concrete `IP:port`. If the DDNS hostname later rebinds to a new IP, the existing runtime endpoint can stay stale for a long time.

This project closes that gap by:

- monitoring stale peer handshakes
- resolving the hostname only when failover is needed
- writing a literal `IP:port` back into the runtime peer endpoint

## Supported Scenarios

This monitor is designed for the following operating model:

- the local host runs WireGuard and owns the runtime endpoint state that may need refreshing
- peer configuration uses `Endpoint=hostname:port`
- the remote peer listens on a stable port, while the hostname may later resolve to a different IP
- peers use `PersistentKeepalive` or otherwise produce traffic often enough that handshake age is a meaningful failure signal
- configuration is managed locally through `/etc/wg-ddns-endpoint-monitor/` and, when auto-discovery is used, `/etc/wireguard/*.conf`

## Non-Goals And Caveats

This project intentionally does not try to solve every WireGuard reachability problem:

- it is not a general WireGuard health checker or monitoring stack
- it is not intended for peers that intentionally roam and update their endpoint IP or port dynamically
- it does not manage peers whose configured endpoint is already a literal IP
- it does not override the host resolver stack or query a custom nameserver directly
- it uses handshake age as the failover signal, so permanently idle peers without keepalive or traffic are a weaker fit
- it keeps the implementation lightweight on purpose, so there is no database, daemon, metrics backend, or active probing subsystem

## Design Summary

The delivered design is intentionally small and operationally simple:

- implementation stays in Bash
- execution model is `systemd timer + oneshot service`
- config-trigger path activation uses `systemd.path`
- no daemon process
- no external database
- runtime state stored only under `/run/wg-ddns-endpoint-monitor`
- concurrency is guarded by a kernel-managed `flock` on `/run/lock/wg-ddns-endpoint-monitor.lock`

Core behavior:

1. If the latest successful handshake is still fresh, the monitor skips DNS entirely.
2. If a peer has never completed a handshake, the monitor first records when that state was observed and waits a full failover window before acting.
3. When failover is needed, the hostname is resolved into a candidate IP set.
4. If the current runtime IP is still a valid candidate, it is preserved when appropriate.
5. If failover is required, the monitor writes a literal `IP:port` with `wg set`, never `hostname:port`.
6. Short cooldown and post-switch grace logic prevent multi-IP hostname flapping.
7. If a second execution is triggered while another monitor process is still running, the later run exits immediately without doing any work.

## Default Behavior

- default timer cadence: `30s`
- `FAILOVER_HANDSHAKE_AGE=180`
- blocked candidate cooldown is derived internally as `2 * FAILOVER_HANDSHAKE_AGE`
- post-switch grace is derived internally from timer cadence and peer keepalive

## Resolver Behavior

The monitor does not hardcode a nameserver.

It uses the host resolver stack through:

- `getent ahosts`
- `getent ahostsv4`
- `getent ahostsv6`

That means it follows `/etc/nsswitch.conf` and `/etc/resolv.conf` on the target host.

## Configuration

Main configuration file:

- `/etc/wg-ddns-endpoint-monitor/config`

Important options:

- `WG_INTERFACES`
- `DISCOVERY_MODE`
- `WG_CONF_DIR`
- `PREFER_FAMILY`
- `FAILOVER_HANDSHAKE_AGE`

Timer cadence is configured through:

- `/etc/systemd/system/wg-ddns-endpoint-monitor.timer.d/override.conf`

Immediate config-triggered runs are provided by:

- `wg-ddns-endpoint-monitor.path`

## How To Use

The monitor supports three common deployment styles:

- default auto-discovery from `/etc/wireguard/<iface>.conf`
- explicit peer list from `/etc/wg-ddns-endpoint-monitor/endpoints.conf`
- mixed mode, where explicit entries override auto-discovered peers
- regardless of discovery mode, runtime refresh always uses a literal `IP:port`

### Example 1: Default Auto-Discovery

This is the simplest and recommended setup when your existing WireGuard config already contains hostname endpoints.

Example `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.20.0.2/24
PrivateKey = <private-key>

[Peer]
PublicKey = <peer-public-key>
AllowedIPs = 10.20.0.1/32
Endpoint = vpn.example.com:51820
PersistentKeepalive = 19
```

Example `/etc/wg-ddns-endpoint-monitor/config`:

```bash
WG_INTERFACES="auto"
DISCOVERY_MODE="auto"
WG_CONF_DIR="/etc/wireguard"
PREFER_FAMILY="auto"
FAILOVER_HANDSHAKE_AGE=180
```

What this means:

- `WG_INTERFACES="auto"` scans all `*.conf` files under `/etc/wireguard`
- `DISCOVERY_MODE="auto"` reads `[Peer] Endpoint=` values directly from those configs
- only hostname endpoints are monitored; literal IP endpoints are ignored
- `FAILOVER_HANDSHAKE_AGE=180` means the monitor only considers failover when the latest successful handshake is older than 180 seconds

This is the right mode when:

- you already manage peers in `wg0.conf`
- you want the monitor to discover hostname peers automatically
- you do not need a separate override list

### Example 2: Explicit Mode

Use this when you only want to monitor a specific subset of peers, or when you do not want to rely on auto-discovery.

Example `/etc/wg-ddns-endpoint-monitor/config`:

```bash
WG_INTERFACES="wg0"
DISCOVERY_MODE="explicit"
WG_CONF_DIR="/etc/wireguard"
PREFER_FAMILY="ipv4"
FAILOVER_HANDSHAKE_AGE=180
```

Example `/etc/wg-ddns-endpoint-monitor/endpoints.conf`:

```text
wg0|<peer-public-key-1>|vpn.example.com:51820
wg0|<peer-public-key-2>|backup.example.com:51820
```

Format of each line:

```text
iface|peer_public_key|endpoint
```

Each line represents one peer entry.

- the same interface name may appear on multiple lines
- this means multiple peers on that interface should be monitored
- if you only have one peer on `wg0`, then `endpoints.conf` only needs one `wg0|...` line

What this means:

- only interface `wg0` is considered
- only peers listed in `endpoints.conf` are monitored
- `PREFER_FAMILY="ipv4"` makes candidate selection and final `wg set` refresh prefer IPv4 addresses

This is the right mode when:

- you want strict control over which peers are monitored
- not every hostname peer should be managed by the tool
- you want to override what is present in `wg0.conf`

### Example 3: Mixed Mode

Use this when you want auto-discovery, but also want a few explicit overrides.

Example `/etc/wg-ddns-endpoint-monitor/config`:

```bash
WG_INTERFACES="wg0 wg1"
DISCOVERY_MODE="mixed"
WG_CONF_DIR="/etc/wireguard"
PREFER_FAMILY="auto"
FAILOVER_HANDSHAKE_AGE=240
```

What this means:

- peers are auto-discovered from `/etc/wireguard/wg0.conf` and `/etc/wireguard/wg1.conf`
- if the same `iface + peer_public_key` also appears in `endpoints.conf`, the explicit entry wins
- `FAILOVER_HANDSHAKE_AGE=240` makes failover more conservative

### Timer Configuration

Timer cadence is not configured in the main monitor config file. It comes from the systemd timer unit.

Default timer override file:

```ini
[Timer]
OnBootSec=
OnUnitActiveSec=
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s
RandomizedDelaySec=1s
```

Path:

- `/etc/systemd/system/wg-ddns-endpoint-monitor.timer.d/override.conf`

If you change it, reload and restart the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl restart wg-ddns-endpoint-monitor.timer
```

### Enable And Run

After configuration is in place:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wg-ddns-endpoint-monitor.timer wg-ddns-endpoint-monitor.path
```

To trigger one immediate run:

```bash
sudo systemctl start wg-ddns-endpoint-monitor.service
```

To inspect behavior:

```bash
systemctl status wg-ddns-endpoint-monitor.timer
systemctl status wg-ddns-endpoint-monitor.path
journalctl -t wg-ddns-endpoint-monitor -n 50 --no-pager
wg show
```

### What To Expect At Runtime

- healthy peers should mostly log `skipped`
- stale peers may log `refreshed` when runtime endpoint failover is needed
- peers with no successful handshake are first observed locally through `NO_HANDSHAKE_SINCE`, then only enter failover logic after a full failover window
- changes to `/etc/wg-ddns-endpoint-monitor/config` or `/etc/wg-ddns-endpoint-monitor/endpoints.conf` trigger an immediate oneshot run through `wg-ddns-endpoint-monitor.path`
- overlapping executions do not run concurrently; a later trigger exits immediately if another process still holds the monitor lock
- runtime state is stored under `/run/wg-ddns-endpoint-monitor`
- hostname resolution uses the host resolver stack from `/etc/nsswitch.conf` and `/etc/resolv.conf`

### Concurrency Semantics

The monitor uses a non-blocking kernel `flock` on:

- `/run/lock/wg-ddns-endpoint-monitor.lock`

This is intentionally not a PID file or a state marker.

- if one monitor process is still alive and holding the lock, a later trigger exits immediately
- if the process exits or crashes, the kernel releases the lock automatically
- the presence of the lock file itself does not mean the lock is still held
- the oneshot service is also bounded by `TimeoutStartSec=60s`, so an unexpectedly long-running process is terminated by systemd instead of blocking future runs indefinitely

### Logging Semantics

The monitor logs in two ways at the same time:

- it sends messages through `logger` with tag `wg-ddns-endpoint-monitor`
- it also prints the same message to standard output when run directly in a terminal

In practice this means:

- `journalctl -t wg-ddns-endpoint-monitor` is the most reliable way to inspect monitor logs
- `journalctl -u wg-ddns-endpoint-monitor.service` may be empty if the useful entries came from the `logger` path rather than unit-managed stdout
- logs may or may not also appear under `/var/log`, depending on how the host forwards journald/syslog messages

Recommended commands:

```bash
journalctl -t wg-ddns-endpoint-monitor -n 50 --no-pager
journalctl -t wg-ddns-endpoint-monitor -f
```

## How To Build

Run the local regression check first:

```bash
tests/product-smoke.sh
```

Then build the Debian package:

```bash
./build-deb.sh
```

By default, the package is written to the project-local `bin/` directory:

```bash
./bin/wg-ddns-endpoint-monitor_<version>_<arch>.deb
```

Or choose an explicit output path:

```bash
./build-deb.sh /tmp/wg-ddns-endpoint-monitor.deb
```

This produces a `.deb` containing the monitor script, systemd unit files, default configuration, and documentation.

Useful package inspection commands:

```bash
dpkg-deb -c ./bin/wg-ddns-endpoint-monitor_<version>_<arch>.deb
dpkg-deb -I ./bin/wg-ddns-endpoint-monitor_<version>_<arch>.deb
```

## Validation

Local regression check:

```bash
tests/product-smoke.sh
```

Installed package documentation:

- `/usr/share/doc/wg-ddns-endpoint-monitor/README.md`

Useful inspection commands:

```bash
journalctl -t wg-ddns-endpoint-monitor -n 50 --no-pager
systemctl status wg-ddns-endpoint-monitor.timer
systemctl status wg-ddns-endpoint-monitor.path
wg show
```

## Status

This version has been validated at four levels:

- static script and packaging checks
- package build verification
- local functional smoke tests
- controlled real-host verification on `wg0`, with runtime endpoint restoration after test
