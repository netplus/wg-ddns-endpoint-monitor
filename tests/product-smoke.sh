#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/usr/libexec/wg-ddns-endpoint-monitor"

HARNESS="$(mktemp)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$HARNESS" "$TEST_ROOT"' EXIT

sed '$d' "$SCRIPT" > "$HARNESS"
# shellcheck disable=SC1090
source "$HARNESS"
eval "$(declare -f collect_entries | sed '1s/collect_entries/orig_collect_entries/')"

PASS_COUNT=0

new_case_env() {
    CASE_DIR="$(mktemp -d "$TEST_ROOT/case.XXXXXX")"
    LOG_FILE="$CASE_DIR/run.log"
    WG_SET_LOG="$CASE_DIR/wg-set.log"
    RUNTIME_FILE="$CASE_DIR/runtime_ep"
    DNS_FILE="$CASE_DIR/dns"
    HS_FILE="$CASE_DIR/hs"
    KEEPALIVE_FILE="$CASE_DIR/keepalive"
    ACTIVE_FILE="$CASE_DIR/active"
    ENTRIES_FILE="$CASE_DIR/entries"
    NOW="$(date +%s)"

    mkdir -p \
        "$CASE_DIR/state" \
        "$CASE_DIR/lock" \
        "$CASE_DIR/etc/systemd/system/wg-ddns-endpoint-monitor.timer.d" \
        "$CASE_DIR/lib/systemd/system"

    cat >"$CASE_DIR/config" <<CFG
WG_INTERFACES="wg0"
DISCOVERY_MODE="explicit"
WG_CONF_DIR="$CASE_DIR/wgconf"
PREFER_FAMILY="auto"
FAILOVER_HANDSHAKE_AGE=180
STATE_DIR="$CASE_DIR/state"
CFG

    : > "$CASE_DIR/endpoints.conf"
    cat >"$CASE_DIR/lib/systemd/system/wg-ddns-endpoint-monitor.timer" <<'TIMER'
[Timer]
OnUnitActiveSec=30s
TIMER
    cat >"$CASE_DIR/etc/systemd/system/wg-ddns-endpoint-monitor.timer.d/override.conf" <<'OVERRIDE'
[Timer]
OnUnitActiveSec=30s
OVERRIDE

    DEFAULT_CONFIG_FILE="$CASE_DIR/config"
    DEFAULT_ENDPOINTS_FILE="$CASE_DIR/endpoints.conf"
    WG_CONF_DIR_DEFAULT="$CASE_DIR/wgconf"
    TIMER_UNIT_NAME="wg-ddns-endpoint-monitor.timer"
    LOCK_FILE="$CASE_DIR/lock/wg-ddns-endpoint-monitor.lock"
    STATE_DIR="$CASE_DIR/state"

    : > "$LOG_FILE"
    : > "$WG_SET_LOG"
    : > "$RUNTIME_FILE"
    : > "$DNS_FILE"
    : > "$HS_FILE"
    : > "$KEEPALIVE_FILE"
    echo 1 > "$ACTIVE_FILE"
    : > "$ENTRIES_FILE"
    mkdir -p "$CASE_DIR/wgconf"
    USE_REAL_COLLECT_ENTRIES=0

    reset_state_vars
}

log() {
    local level="$1"; shift
    printf '%s|%s\n' "$level" "$*" >> "$LOG_FILE"
}

collect_entries() {
    if [[ "${USE_REAL_COLLECT_ENTRIES:-0}" == "1" ]]; then
        orig_collect_entries
    else
        cat "$ENTRIES_FILE"
    fi
}

iface_active() {
    [[ $(cat "$ACTIVE_FILE") == "1" ]]
}

latest_handshake() {
    local key="$1|$2"
    awk -F'=' -v k="$key" '$1 == k { print $2; exit }' "$HS_FILE"
}

current_runtime_endpoint() {
    local key="$1|$2"
    awk -F'=' -v k="$key" '$1 == k { print $2; exit }' "$RUNTIME_FILE"
}

peer_keepalive() {
    local key="$1|$2"
    awk -F'=' -v k="$key" '$1 == k { print $2; exit }' "$KEEPALIVE_FILE"
}

resolve_host() {
    local host="$1"
    awk -F'=' -v h="$host" '$1 == h { print $2 }' "$DNS_FILE"
}

wg() {
    if [[ "$1" == "show" ]]; then
        return 0
    fi
    if [[ "$1" == "set" ]]; then
        local iface="$2" pub="$4" endpoint="$6" key tmp
        printf '%s|%s|%s\n' "$iface" "$pub" "$endpoint" >> "$WG_SET_LOG"
        key="$iface|$pub"
        tmp="$(mktemp)"
        awk -F'=' -v k="$key" -v v="$endpoint" '
            BEGIN { done = 0 }
            $1 == k { print k "=" v; done = 1; next }
            { print }
            END { if (!done) print k "=" v }
        ' "$RUNTIME_FILE" > "$tmp"
        mv "$tmp" "$RUNTIME_FILE"
        return 0
    fi
    printf 'unexpected wg invocation: %s\n' "$*" >&2
    return 1
}

assert_contains() {
    local file="$1" needle="$2"
    grep -F "$needle" "$file" >/dev/null
}

state_path() {
    state_file_path "$1" "$2"
}

run_case() {
    local name="$1" fn="$2"
    new_case_env
    "$fn"
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS %s\n' "$name"
}

case_fresh_skip_dns() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo "wg0|peerA=$((NOW - 50))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"
    echo 'wg0|peerA=25' > "$KEEPALIVE_FILE"

    main

    [[ ! -s "$WG_SET_LOG" ]]
    local state
    state="$(state_path wg0 peerA)"
    assert_contains "$state" 'SELECTED_IP=10.0.0.1'
    assert_contains "$state" 'NO_HANDSHAKE_SINCE=0'
    assert_contains "$LOG_FILE" 'skipped: handshake_age=50s threshold=180s'
}

case_stale_runtime_valid_failover_literal_ip() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo "wg0|peerA=$((NOW - 300))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"
    cat >"$DNS_FILE" <<'DNS'
vpn.example.com=10.0.0.1
vpn.example.com=10.0.0.2
DNS

    main

    assert_contains "$WG_SET_LOG" 'wg0|peerA|10.0.0.2:51820'
    local state
    state="$(state_path wg0 peerA)"
    assert_contains "$state" 'SELECTED_IP=10.0.0.2'
    grep -E '^BLOCKED_ENTRIES=10\.0\.0\.1@[0-9]+$' "$state" >/dev/null
}

case_post_switch_grace_blocks_immediate_reswitch() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo "wg0|peerA=$((NOW - 300))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.2:51820' > "$RUNTIME_FILE"
    echo 'wg0|peerA=25' > "$KEEPALIVE_FILE"
    cat >"$DNS_FILE" <<'DNS'
vpn.example.com=10.0.0.1
vpn.example.com=10.0.0.2
DNS

    local state
    state="$(state_path wg0 peerA)"
    cat >"$state" <<EOFSTATE
CONFIG_FINGERPRINT=wg0|peerA|vpn.example.com|51820|auto
SELECTED_IP=10.0.0.2
LAST_SWITCH_TS=$((NOW - 10))
NO_HANDSHAKE_SINCE=0
BLOCKED_ENTRIES=10.0.0.1@$((NOW + 300))
EOFSTATE

    main

    [[ ! -s "$WG_SET_LOG" ]]
    assert_contains "$LOG_FILE" 'within post-switch grace='
}

case_all_candidates_blocked_pick_earliest() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo "wg0|peerA=$((NOW - 300))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.9:51820' > "$RUNTIME_FILE"
    cat >"$DNS_FILE" <<'DNS'
vpn.example.com=10.0.0.1
vpn.example.com=10.0.0.2
DNS

    local state
    state="$(state_path wg0 peerA)"
    cat >"$state" <<EOFSTATE
CONFIG_FINGERPRINT=wg0|peerA|vpn.example.com|51820|auto
SELECTED_IP=10.0.0.9
LAST_SWITCH_TS=0
NO_HANDSHAKE_SINCE=0
BLOCKED_ENTRIES=10.0.0.1@$((NOW + 300)),10.0.0.2@$((NOW + 200))
EOFSTATE

    main

    assert_contains "$WG_SET_LOG" 'wg0|peerA|10.0.0.2:51820'
}

case_no_handshake_first_seen_records_only() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo 'wg0|peerA=0' > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"

    main

    [[ ! -s "$WG_SET_LOG" ]]
    local state
    state="$(state_path wg0 peerA)"
    assert_contains "$state" "NO_HANDSHAKE_SINCE=$NOW"
    assert_contains "$LOG_FILE" 'first no-handshake observation recorded'
}

case_no_handshake_wait_then_failover() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo 'wg0|peerA=0' > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"
    cat >"$DNS_FILE" <<'DNS'
vpn.example.com=10.0.0.1
vpn.example.com=10.0.0.2
DNS

    local state
    state="$(state_path wg0 peerA)"
    cat >"$state" <<EOFSTATE
CONFIG_FINGERPRINT=wg0|peerA|vpn.example.com|51820|auto
SELECTED_IP=10.0.0.1
LAST_SWITCH_TS=0
NO_HANDSHAKE_SINCE=$((NOW - 200))
BLOCKED_ENTRIES=
EOFSTATE

    main

    assert_contains "$WG_SET_LOG" 'wg0|peerA|10.0.0.2:51820'
    assert_contains "$LOG_FILE" 'no_handshake_age=200s reason=failover_from_runtime'
}

case_corrupted_state_is_dropped_and_rebuilt() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo "wg0|peerA=$((NOW - 50))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"

    local state
    state="$(state_path wg0 peerA)"
    cat >"$state" <<'EOFSTATE'
CONFIG_FINGERPRINT=wg0|peerA|vpn.example.com|51820|auto
SELECTED_IP=10.0.0.1
LAST_SWITCH_TS=oops
NO_HANDSHAKE_SINCE=0
BLOCKED_ENTRIES=
EOFSTATE

    main

    assert_contains "$state" 'LAST_SWITCH_TS=0'
    assert_contains "$state" 'SELECTED_IP=10.0.0.1'
}

case_malformed_blocked_entries_are_dropped_and_rebuilt() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo "wg0|peerA=$((NOW - 50))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"

    local state
    state="$(state_path wg0 peerA)"
    cat >"$state" <<'EOFSTATE'
CONFIG_FINGERPRINT=wg0|peerA|vpn.example.com|51820|auto
SELECTED_IP=10.0.0.1
LAST_SWITCH_TS=0
NO_HANDSHAKE_SINCE=0
BLOCKED_ENTRIES=bad-entry
EOFSTATE

    main

    assert_contains "$state" 'SELECTED_IP=10.0.0.1'
    assert_contains "$state" 'BLOCKED_ENTRIES='
}

case_legacy_state_version_is_dropped_and_rebuilt() {
    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo "wg0|peerA=$((NOW - 50))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"

    local state
    state="$(state_path wg0 peerA)"
    cat >"$state" <<'EOFSTATE'
STATE_VERSION=2
CONFIG_FINGERPRINT=wg0|peerA|vpn.example.com|51820|auto
SELECTED_IP=10.0.0.1
LAST_SWITCH_TS=0
NO_HANDSHAKE_SINCE=0
BLOCKED_ENTRIES=
EOFSTATE

    main

    assert_contains "$state" 'SELECTED_IP=10.0.0.1'
    ! grep -q '^STATE_VERSION=' "$state"
    assert_contains "$state" 'LAST_SWITCH_TS=0'
}

case_prefer_family_ipv4_writes_literal_ipv4() {
    cat >"$CASE_DIR/config" <<CFG
WG_INTERFACES="wg0"
DISCOVERY_MODE="explicit"
WG_CONF_DIR="$CASE_DIR/wgconf"
PREFER_FAMILY="ipv4"
FAILOVER_HANDSHAKE_AGE=180
STATE_DIR="$CASE_DIR/state"
CFG

    echo 'wg0|peerA|vpn.example.com:51820' > "$ENTRIES_FILE"
    echo "wg0|peerA=$((NOW - 300))" > "$HS_FILE"
    echo 'wg0|peerA=[2001:db8::1]:51820' > "$RUNTIME_FILE"
    echo 'vpn.example.com=10.0.0.4' > "$DNS_FILE"

    main

    assert_contains "$WG_SET_LOG" 'wg0|peerA|10.0.0.4:51820'
}

case_auto_mode_writes_literal_ip() {
    cat >"$CASE_DIR/config" <<CFG
WG_INTERFACES="wg0"
DISCOVERY_MODE="auto"
WG_CONF_DIR="$CASE_DIR/wgconf"
PREFER_FAMILY="auto"
FAILOVER_HANDSHAKE_AGE=180
STATE_DIR="$CASE_DIR/state"
CFG

    cat >"$CASE_DIR/wgconf/wg0.conf" <<'WGCONF'
[Interface]
Address = 10.20.0.2/24
PrivateKey = <private-key>

[Peer]
PublicKey = peerA
Endpoint = vpn.example.com:51820
AllowedIPs = 10.20.0.1/32
WGCONF

    USE_REAL_COLLECT_ENTRIES=1
    echo "wg0|peerA=$((NOW - 300))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"
    cat >"$DNS_FILE" <<'DNS'
vpn.example.com=10.0.0.1
vpn.example.com=10.0.0.8
DNS

    main

    assert_contains "$WG_SET_LOG" 'wg0|peerA|10.0.0.8:51820'
}

case_mixed_mode_explicit_override_writes_literal_ip() {
    cat >"$CASE_DIR/config" <<CFG
WG_INTERFACES="wg0"
DISCOVERY_MODE="mixed"
WG_CONF_DIR="$CASE_DIR/wgconf"
PREFER_FAMILY="auto"
FAILOVER_HANDSHAKE_AGE=180
STATE_DIR="$CASE_DIR/state"
CFG

    cat >"$CASE_DIR/wgconf/wg0.conf" <<'WGCONF'
[Interface]
Address = 10.20.0.2/24
PrivateKey = <private-key>

[Peer]
PublicKey = peerA
Endpoint = auto.example.com:51820
AllowedIPs = 10.20.0.1/32
WGCONF

    cat >"$CASE_DIR/endpoints.conf" <<'ENDPOINTS'
wg0|peerA|override.example.com:51820
ENDPOINTS

    USE_REAL_COLLECT_ENTRIES=1
    echo "wg0|peerA=$((NOW - 300))" > "$HS_FILE"
    echo 'wg0|peerA=10.0.0.1:51820' > "$RUNTIME_FILE"
    cat >"$DNS_FILE" <<'DNS'
auto.example.com=10.0.0.7
override.example.com=10.0.0.9
override.example.com=10.0.0.1
DNS

    main

    assert_contains "$WG_SET_LOG" 'wg0|peerA|10.0.0.9:51820'
    local state
    state="$(state_path wg0 peerA)"
    assert_contains "$state" 'CONFIG_FINGERPRINT=wg0|peerA|override.example.com|51820|auto'
}

case_second_run_exits_immediately_when_process_holds_lock() {
    local ext_script ext_cfg log1 log2

    ext_script="$CASE_DIR/lock-check.sh"
    ext_cfg="$CASE_DIR/lock-check.conf"
    log1="$CASE_DIR/lock-check-1.log"
    log2="$CASE_DIR/lock-check-2.log"

    cp "$SCRIPT" "$ext_script"
    python3 - "$ext_script" "$ext_cfg" "$CASE_DIR/lock/external.lock" <<'PY'
from pathlib import Path
import sys

script = Path(sys.argv[1])
cfg = sys.argv[2]
lock_file = sys.argv[3]
text = script.read_text()
text = text.replace('DEFAULT_CONFIG_FILE="/etc/${PROG}/config"', f'DEFAULT_CONFIG_FILE="{cfg}"')
text = text.replace('LOCK_FILE="/run/lock/${PROG}.lock"', f'LOCK_FILE="{lock_file}"')
text = text.replace('    load_config\n', '    sleep 2\n\n    load_config\n', 1)
script.write_text(text)
PY
    chmod +x "$ext_script"

    cat >"$ext_cfg" <<CFG
WG_INTERFACES=""
DISCOVERY_MODE="auto"
STATE_DIR="$CASE_DIR/state-external"
CFG

    "$ext_script" >"$log1" 2>&1 &
    local pid1=$!
    sleep 0.3
    "$ext_script" >"$log2" 2>&1 || true
    wait "$pid1"

    assert_contains "$log2" 'another run is still active; skip'
}

run_case fresh_skip_dns case_fresh_skip_dns
run_case stale_runtime_valid_failover_literal_ip case_stale_runtime_valid_failover_literal_ip
run_case post_switch_grace_blocks_immediate_reswitch case_post_switch_grace_blocks_immediate_reswitch
run_case all_candidates_blocked_pick_earliest case_all_candidates_blocked_pick_earliest
run_case no_handshake_first_seen_records_only case_no_handshake_first_seen_records_only
run_case no_handshake_wait_then_failover case_no_handshake_wait_then_failover
run_case corrupted_state_is_dropped_and_rebuilt case_corrupted_state_is_dropped_and_rebuilt
run_case malformed_blocked_entries_are_dropped_and_rebuilt case_malformed_blocked_entries_are_dropped_and_rebuilt
run_case legacy_state_version_is_dropped_and_rebuilt case_legacy_state_version_is_dropped_and_rebuilt
run_case prefer_family_ipv4_writes_literal_ipv4 case_prefer_family_ipv4_writes_literal_ipv4
run_case auto_mode_writes_literal_ip case_auto_mode_writes_literal_ip
run_case mixed_mode_explicit_override_writes_literal_ip case_mixed_mode_explicit_override_writes_literal_ip
run_case second_run_exits_immediately_when_process_holds_lock case_second_run_exits_immediately_when_process_holds_lock

printf 'TOTAL_PASS=%s\n' "$PASS_COUNT"
