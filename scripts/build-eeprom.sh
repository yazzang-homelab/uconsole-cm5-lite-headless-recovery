#!/usr/bin/env bash
#
# build-eeprom.sh — Build a CM5 EEPROM update (recovery.bin + pieeprom.upd)
# carrying the uConsole CM5 Lite SD-detection workaround config.
#
# Output files are meant to be copied onto the FAT *boot* partition of the
# uConsole SD card; on next boot the Pi BootROM flashes the EEPROM with no
# OS/monitor required, then renames recovery.bin -> RECOVERY.000.
#
# Usage:
#   ./build-eeprom.sh [OUT_DIR]
# Default OUT_DIR is ./out
#
# Requires: git, plus the rpi-eeprom repo's rpi-eeprom-config (pulled in here).
# Run on any Linux host (the EEPROM image itself is for the CM5, not the host).

set -euo pipefail

OUT_DIR="${1:-./out}"
CONFIG="$(cd "$(dirname "$0")" && pwd)/uconsole-eeprom.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$CONFIG" ] || { echo "ERROR: config not found: $CONFIG" >&2; exit 1; }
mkdir -p "$OUT_DIR"

echo ">> Cloning raspberrypi/rpi-eeprom ..."
git clone --depth 1 https://github.com/raspberrypi/rpi-eeprom "$WORK/rpi-eeprom" >/dev/null 2>&1

FW_DIR="$WORK/rpi-eeprom/firmware-2712/latest"
[ -d "$FW_DIR" ] || FW_DIR="$WORK/rpi-eeprom/firmware-2712/default"
[ -d "$FW_DIR" ] || { echo "ERROR: firmware-2712 dir not found" >&2; exit 1; }

# Pick the newest pieeprom-YYYY-MM-DD.bin (must be >= 2025-01-06 for the CM5 Lite fix).
SRC="$(ls -1 "$FW_DIR"/pieeprom-*.bin 2>/dev/null | sort | tail -1)"
[ -n "$SRC" ] || { echo "ERROR: no pieeprom-*.bin in $FW_DIR" >&2; exit 1; }
REC="$FW_DIR/recovery.bin"
[ -f "$REC" ] || { echo "ERROR: recovery.bin not found in $FW_DIR" >&2; exit 1; }

echo ">> Using firmware: $(basename "$SRC")"
case "$(basename "$SRC")" in
  pieeprom-2024-*|pieeprom-2023-*) echo "WARNING: firmware predates 2025-01-06; CM5 Lite SD fix may be absent." >&2 ;;
esac

echo ">> Applying config ($(basename "$CONFIG")) ..."
"$WORK/rpi-eeprom/rpi-eeprom-config" --config "$CONFIG" --out "$OUT_DIR/pieeprom.upd" "$SRC"
cp "$REC" "$OUT_DIR/recovery.bin"

# Generate pieeprom.sig (SHA-256 digest of pieeprom.upd). Recent recovery.bin
# builds verify the EEPROM image against this signature and will REFUSE to
# flash if pieeprom.sig is absent — so all THREE files must land on the boot
# partition (recovery.bin + pieeprom.upd + pieeprom.sig).
echo ">> Generating pieeprom.sig ..."
"$WORK/rpi-eeprom/rpi-eeprom-digest" -i "$OUT_DIR/pieeprom.upd" -o "$OUT_DIR/pieeprom.sig"

echo ">> Verifying baked-in config:"
"$WORK/rpi-eeprom/rpi-eeprom-config" "$OUT_DIR/pieeprom.upd" | grep -vE '^\s*#|^\s*$' | sed 's/^/     /'

cat <<EOF

Done. Files written to: $OUT_DIR
  - recovery.bin   (BootROM EEPROM-flash trigger)
  - pieeprom.upd   (new EEPROM image)
  - pieeprom.sig   (SHA-256 digest — recovery.bin refuses to flash without it)

Next: copy ALL THREE files onto the FAT boot partition of the uConsole SD card
(inject-headless.sh does this for you), then boot the uConsole once.

NOTE: keep SD_QUIRKS=1 in the config (uconsole-eeprom.txt). It is load-bearing
on this CM5 Lite + SD card *even on the latest firmware* — a 2026/06/17 unit
regressed to "green LED, black screen" after a reboot once the quirk was dropped,
and re-adding it on the same firmware fixed it. Updating the firmware is good
hygiene but is NOT a substitute for the quirk. See docs/FIRMWARE-UPDATE.md.
EOF
