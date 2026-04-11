#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

log() {
    echo "[build-deb] $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_cmd dpkg-deb
require_cmd awk
require_cmd chmod
require_cmd find
require_cmd cp
require_cmd rm
require_cmd mktemp

[[ -f DEBIAN/control ]] || die "DEBIAN/control not found; please run this script from the package root"
[[ -d DEBIAN ]] || die "DEBIAN directory not found"

PACKAGE="$(awk -F': *' '$1=="Package" {print $2; exit}' DEBIAN/control)"
VERSION="$(awk -F': *' '$1=="Version" {print $2; exit}' DEBIAN/control)"
ARCH="$(awk -F': *' '$1=="Architecture" {print $2; exit}' DEBIAN/control)"

[[ -n "$PACKAGE" ]] || die "failed to parse Package from DEBIAN/control"
[[ -n "$VERSION" ]] || die "failed to parse Version from DEBIAN/control"
[[ -n "$ARCH" ]] || die "failed to parse Architecture from DEBIAN/control"

DEFAULT_OUT="$(cd .. && pwd)/${PACKAGE}_${VERSION}_${ARCH}.deb"
OUT_PATH="${1:-$DEFAULT_OUT}"
case "$OUT_PATH" in
    /*) ;;
    *) OUT_PATH="$ROOT_DIR/$OUT_PATH" ;;
esac

mkdir -p "$(dirname "$OUT_PATH")"

log "package root: $ROOT_DIR"
log "output file : $OUT_PATH"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

for path in DEBIAN etc lib usr; do
    [[ -e "$path" ]] || continue
    cp -a "$path" "$STAGE_DIR/"
done

mkdir -p "$STAGE_DIR/usr/share/doc/$PACKAGE"
cp "$ROOT_DIR/README.md" "$STAGE_DIR/usr/share/doc/$PACKAGE/README.md"

cd "$STAGE_DIR"
chmod 0755 "$STAGE_DIR"

# Normalize directory permissions so package output does not inherit a group-writable
# workspace tree.
find "$STAGE_DIR" -type d -exec chmod 0755 {} +

# Normalize the most important Debian package permissions inside the staging tree.
chmod 0755 DEBIAN
for f in control conffiles; do
    [[ -e "DEBIAN/$f" ]] && chmod 0644 "DEBIAN/$f"
done
for f in preinst postinst prerm postrm config; do
    [[ -e "DEBIAN/$f" ]] && chmod 0755 "DEBIAN/$f"
done
[[ -e usr/libexec/wg-ddns-endpoint-monitor ]] && chmod 0755 usr/libexec/wg-ddns-endpoint-monitor
[[ -e lib/systemd/system/wg-ddns-endpoint-monitor.service ]] && chmod 0644 lib/systemd/system/wg-ddns-endpoint-monitor.service
[[ -e lib/systemd/system/wg-ddns-endpoint-monitor.path ]] && chmod 0644 lib/systemd/system/wg-ddns-endpoint-monitor.path
[[ -e lib/systemd/system/wg-ddns-endpoint-monitor.timer ]] && chmod 0644 lib/systemd/system/wg-ddns-endpoint-monitor.timer
[[ -e etc/systemd/system/wg-ddns-endpoint-monitor.timer.d/override.conf ]] && chmod 0644 etc/systemd/system/wg-ddns-endpoint-monitor.timer.d/override.conf
[[ -e etc/wg-ddns-endpoint-monitor/config ]] && chmod 0644 etc/wg-ddns-endpoint-monitor/config
[[ -e etc/wg-ddns-endpoint-monitor/endpoints.conf ]] && chmod 0644 etc/wg-ddns-endpoint-monitor/endpoints.conf
[[ -e usr/share/doc/wg-ddns-endpoint-monitor/README.md ]] && chmod 0644 usr/share/doc/wg-ddns-endpoint-monitor/README.md

TMP_OUT="${OUT_PATH}.tmp"
rm -f "$TMP_OUT"

dpkg-deb --build --root-owner-group "$STAGE_DIR" "$TMP_OUT" >/dev/null
mv -f "$TMP_OUT" "$OUT_PATH"

log "build completed"
log "created: $OUT_PATH"
