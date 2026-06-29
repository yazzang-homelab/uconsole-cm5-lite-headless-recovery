#!/usr/bin/env bash
#
# inject-headless.sh — Make a uConsole CM5 Lite SD card boot headlessly.
#
# In one pass on the SD card it:
#   1. copies recovery.bin + pieeprom.upd to the FAT boot partition  (EEPROM update)
#   2. enables SSH (boot/ssh flag + rootfs ssh.service symlink)
#   3. writes a NetworkManager Wi-Fi connection (+ wpa_supplicant fallback)
#   4. installs your SSH public key for root and allows key-only root login
#   5. removes init=.../firstboot from cmdline.txt so it boots straight to systemd
#
# Run on a Linux host with the SD card inserted. Root required (mount + chown).
#
# Usage:
#   sudo ./inject-headless.sh --dev /dev/sdX --eeprom ./out \
#        --ssid 'MySSID' --psk 'MyPassphraseOr64HexPSK' \
#        --pubkey ~/.ssh/id_ed25519.pub
#
#   --dev      Base device of the SD card (partitions <dev>1 boot, <dev>2 root)
#   --eeprom   Dir containing recovery.bin + pieeprom.upd (from build-eeprom.sh); optional
#   --ssid     Wi-Fi SSID                                                          ; optional
#   --psk      Wi-Fi passphrase (8-63 chars) or raw 64-hex PSK                      ; optional
#   --pubkey   Path to an SSH public key to authorize for root                      ; optional
#   --keep-firstboot   Do NOT remove init=.../firstboot (default: remove it)
#
# Everything is idempotent; re-running is safe.

set -euo pipefail

DEV="" EEPROM_DIR="" SSID="" PSK="" PUBKEY="" KEEP_FIRSTBOOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dev) DEV="$2"; shift 2;;
    --eeprom) EEPROM_DIR="$2"; shift 2;;
    --ssid) SSID="$2"; shift 2;;
    --psk) PSK="$2"; shift 2;;
    --pubkey) PUBKEY="$2"; shift 2;;
    --keep-firstboot) KEEP_FIRSTBOOT=1; shift;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$DEV" ] || { echo "ERROR: --dev /dev/sdX is required" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)" >&2; exit 2; }
BOOTP="${DEV}1"; ROOTP="${DEV}2"
[ -b "$BOOTP" ] && [ -b "$ROOTP" ] || { echo "ERROR: $BOOTP / $ROOTP not found" >&2; exit 2; }

MB="$(mktemp -d)"; MR="$(mktemp -d)"
cleanup(){ sync; umount "$MB" 2>/dev/null || true; umount "$MR" 2>/dev/null || true; rmdir "$MB" "$MR" 2>/dev/null || true; }
trap cleanup EXIT

mount "$BOOTP" "$MB"
mount "$ROOTP" "$MR"
echo ">> boot=$BOOTP root=$ROOTP"
echo ">> OS: $(grep -oE 'PRETTY_NAME=.*' "$MR/etc/os-release" 2>/dev/null | cut -d'"' -f2)"

# 1) EEPROM files -------------------------------------------------------------
if [ -n "$EEPROM_DIR" ]; then
  for f in recovery.bin pieeprom.upd; do
    [ -f "$EEPROM_DIR/$f" ] || { echo "ERROR: $EEPROM_DIR/$f missing" >&2; exit 1; }
    cp "$EEPROM_DIR/$f" "$MB/$f"; echo "   + $f -> boot"
  done
fi

# 2) Enable SSH ---------------------------------------------------------------
touch "$MB/ssh"
if [ -e "$MR/lib/systemd/system/ssh.service" ]; then
  mkdir -p "$MR/etc/systemd/system/multi-user.target.wants"
  ln -sf /lib/systemd/system/ssh.service \
     "$MR/etc/systemd/system/multi-user.target.wants/ssh.service"
  echo "   + ssh.service enabled (rootfs symlink)"
fi

# 3) Wi-Fi --------------------------------------------------------------------
if [ -n "$SSID" ] && [ -n "$PSK" ]; then
  NMDIR="$MR/etc/NetworkManager/system-connections"
  if [ -d "$(dirname "$NMDIR")" ]; then
    mkdir -p "$NMDIR"
    # NetworkManager: a 64-hex string is a raw PSK; otherwise it's a passphrase.
    cat > "$NMDIR/${SSID}.nmconnection" <<EOF
[connection]
id=${SSID}
type=wifi
autoconnect=true
[wifi]
mode=infrastructure
ssid=${SSID}
[wifi-security]
key-mgmt=wpa-psk
psk=${PSK}
[ipv4]
method=auto
[ipv6]
method=auto
EOF
    chmod 600 "$NMDIR/${SSID}.nmconnection"; chown 0:0 "$NMDIR/${SSID}.nmconnection"
    echo "   + NetworkManager connection for SSID '$SSID'"
  fi
  # Fallback for non-NM images:
  WPA="ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US
network={
    ssid=\"${SSID}\"
    psk=\"${PSK}\"
}"
  [ -d "$MR/etc/wpa_supplicant" ] && printf '%s\n' "$WPA" > "$MR/etc/wpa_supplicant/wpa_supplicant.conf"
  printf '%s\n' "$WPA" > "$MB/wpa_supplicant.conf" 2>/dev/null || true
fi

# 4) SSH key for root ---------------------------------------------------------
if [ -n "$PUBKEY" ]; then
  [ -f "$PUBKEY" ] || { echo "ERROR: pubkey not found: $PUBKEY" >&2; exit 1; }
  mkdir -p "$MR/root/.ssh"
  PUB="$(cat "$PUBKEY")"
  grep -qF "$PUB" "$MR/root/.ssh/authorized_keys" 2>/dev/null || \
    printf '%s\n' "$PUB" >> "$MR/root/.ssh/authorized_keys"
  chmod 700 "$MR/root/.ssh"; chmod 600 "$MR/root/.ssh/authorized_keys"; chown -R 0:0 "$MR/root/.ssh"
  mkdir -p "$MR/etc/ssh/sshd_config.d"
  echo "PermitRootLogin prohibit-password" > "$MR/etc/ssh/sshd_config.d/99-uconsole.conf"
  echo "   + root key authorized; PermitRootLogin prohibit-password"
fi

# 5) Remove firstboot ---------------------------------------------------------
CMDLINE="$MB/cmdline.txt"
[ -f "$CMDLINE" ] || CMDLINE="$MB/firmware/cmdline.txt"
if [ "$KEEP_FIRSTBOOT" -eq 0 ] && [ -f "$CMDLINE" ]; then
  if grep -q 'firstboot' "$CMDLINE"; then
    sed -i 's#[[:space:]]*init=/usr/lib/raspberrypi-sys-mods/firstboot##g' "$CMDLINE"
    echo "   + removed init=.../firstboot from cmdline.txt"
  else
    echo "   = no firstboot token in cmdline.txt (already clean)"
  fi
fi

sync
echo ">> Done. boot partition now contains:"
ls "$MB" | grep -iE 'recovery|pieeprom|ssh|cmdline' | sed 's/^/     /'
echo ">> Unmounting (via trap)."
