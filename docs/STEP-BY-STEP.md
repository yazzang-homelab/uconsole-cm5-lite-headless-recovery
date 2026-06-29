# Step-by-Step Headless Recovery

Goal: take a uConsole CM5 Lite that shows only a green LED and a black screen and **never joins the network**, and end up SSH'd into a fully booted system — without ever using a monitor.

You will do all the SD-card work on a **second Linux machine** ("the host"). Replace placeholders: `/dev/sdX` (your SD card), `WIFI_SSID`, `WIFI_PSK`, and your SSH public key.

> Read [ROOT-CAUSE.md](ROOT-CAUSE.md) if you want to know *why* each step exists. Read the [reader note](TROUBLESHOOTING.md#unreliable-usb-card-readers) before you start — a flaky USB reader will cost you hours.

---

## Step 0 — Identify the SD card on the host

Insert the SD into the host's reader and confirm the device node and partitions:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,TRAN
# Expect two partitions: <dev>1 vfat LABEL=bootfs, <dev>2 ext4 LABEL=rootfs
```

Throughout, `/dev/sdX1` = the FAT **boot** partition, `/dev/sdX2` = the ext4 **root** partition. Create mountpoints:

```bash
sudo mkdir -p /mnt/boot /mnt/root
```

---

## Step 1 — Build the EEPROM update (fixes Cause A)

On the host, build a `recovery.bin` + a configured `pieeprom.upd` from the official Raspberry Pi EEPROM images. The config is what defeats the CM5 Lite SD-detection bug.

```bash
./scripts/build-eeprom.sh ./out
# produces ./out/recovery.bin and ./out/pieeprom.upd
```

What it does (see [`scripts/build-eeprom.sh`](../scripts/build-eeprom.sh)):
1. `git clone` `raspberrypi/rpi-eeprom`.
2. Picks the newest `firmware-2712/latest/pieeprom-YYYY-MM-DD.bin` (must be ≥ 2025-01-06).
3. Applies [`scripts/uconsole-eeprom.txt`](../scripts/uconsole-eeprom.txt) with `rpi-eeprom-config`, producing `pieeprom.upd`.
4. Copies the matching `recovery.bin`.

The config it bakes in:

```ini
BOOT_UART=1
POWER_OFF_ON_HALT=1
BOOT_ORDER=0xf461       # SD -> NVMe -> USB -> Network
SD_BOOT_MAX_RETRIES=2
SD_QUIRKS=1             # the key line: slow SDR mode in the bootloader
```

---

## Step 2 — Flash a uConsole-specific OS image (fixes Cause B)

On your normal workstation, use **Raspberry Pi Imager → Choose OS → Use custom** and select a **uConsole image** (community "REX" Debian Trixie/Bookworm or equivalent). **Do not** use stock Raspberry Pi OS — it lacks the panel/keyboard/Wi-Fi overlays.

You can skip Imager's SSH/Wi-Fi customisation — Step 3 injects those directly (more reliable for custom images).

Verify it's really a uConsole image (on the host, after re-inserting the SD):

```bash
sudo mount /dev/sdX1 /mnt/boot
grep -i 'clockworkpi-uconsole' /mnt/boot/config.txt   # must match (e.g. clockworkpi-uconsole-cm5)
ls /mnt/boot/kernel_2712.img                          # should exist
sudo umount /mnt/boot
```

---

## Step 3 — Inject EEPROM + SSH + Wi-Fi + key, and remove firstboot (fixes A delivery + C)

This is the one pass that makes the card boot **headless**. Use [`scripts/inject-headless.sh`](../scripts/inject-headless.sh):

```bash
sudo ./scripts/inject-headless.sh \
  --dev /dev/sdX \
  --eeprom ./out \
  --ssid 'WIFI_SSID' \
  --psk  'WIFI_PSK' \
  --pubkey ~/.ssh/id_ed25519.pub
```

It performs, on the mounted card:

1. **EEPROM delivery** — copies `recovery.bin` and `pieeprom.upd` to the FAT boot partition.
2. **Enable SSH** — `touch /boot/ssh` *and* (reliably) creates the `ssh.service` symlink in the rootfs `multi-user.target.wants/` (the `/boot/ssh` flag alone is a legacy mechanism that may not fire on these images).
3. **Wi-Fi** — writes a NetworkManager connection (`/etc/NetworkManager/system-connections/<SSID>.nmconnection`, mode 600) with `autoconnect=true`. A `wpa_supplicant.conf` is also dropped as a fallback. A 64-hex PSK is written verbatim (NetworkManager treats it as a raw PSK); an 8–63 char passphrase is quoted.
4. **SSH key** — appends your public key to `/root/.ssh/authorized_keys` (700/600, root-owned) and adds `PermitRootLogin prohibit-password` via a `sshd_config.d` drop-in (key login works, password login stays closed).
5. **Remove firstboot** — strips `init=/usr/lib/raspberrypi-sys-mods/firstboot` from `cmdline.txt` so the kernel boots straight into `systemd`.

It then `sync`s and unmounts. (See the script for exact commands; everything is idempotent.)

---

## Step 4 — Boot the uConsole

1. Move the SD into the uConsole, power on.
2. **First boot = EEPROM flash.** The BootROM consumes `recovery.bin` and writes the new EEPROM. Because `POWER_OFF_ON_HALT=1`, the unit **may power itself off** when done — wait ~1–2 minutes. (The internal ACT LED blinks during the flash, but it's hidden inside the shell, so you may see no visible change on the power LED.)
3. **Power on again = OS boot.** The updated bootloader now reads the SD (`SD_QUIRKS`), loads the kernel, and — with `firstboot` gone — goes straight to `systemd` → `NetworkManager` → Wi-Fi.
4. Give it 2–3 minutes to join Wi-Fi on the first real boot.

If after a couple of minutes it isn't reachable, do a clean power cycle (double-tap to shut down; avoid long-press hard resets — see [GLOD](TROUBLESHOOTING.md#green-light-of-death-glod)).

---

## Step 5 — Find it and log in

The image's hostname is typically `clockworkpi`, and `avahi-daemon` is enabled, so mDNS works:

```bash
# From any machine on the same LAN:
ping clockworkpi.local
ssh root@clockworkpi.local          # key auth; no password needed

# If mDNS is blocked, scan the subnet for the new SSH host:
sudo arp-scan --localnet | sort
nmap -p22 --open 192.168.0.0/24     # adjust to your subnet
```

Confirm the recovery:

```bash
hostname
cat /proc/device-tree/model         # Raspberry Pi Compute Module 5 Lite ...
vcgencmd version                    # bootloader date should be >= 2025-01-06
df -h /                             # check if you need to expand the rootfs
nmcli -t -f NAME,DEVICE,STATE connection show --active
dmesg | grep -i panel               # 'panel-cwu50 ... rp1dsi_bind succeeded' = panel up
```

---

## Step 6 — Post-recovery hardening & integration (recommended)

```bash
# Expand the rootfs if df showed it small (skip if the image already did it):
sudo raspi-config --expand-rootfs   # or: parted + resize2fs

# Set timezone:
sudo timedatectl set-timezone Area/City

# Update (accept the repo Label change some uConsole images trigger):
sudo apt-get update --allow-releaseinfo-change && sudo apt-get -y full-upgrade

# Set a real password for the default user / change any exposed password:
sudo passwd <user>

# Optional: join a mesh VPN for access from anywhere (browser login, no key in shell):
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --hostname=uconsole
# open the printed https://login.tailscale.com/... URL and authorize
```

After Tailscale is up you get a stable `100.x` address and can reach the uConsole from any network, regardless of DHCP changes on the LAN.

> **Panel still black after a successful boot?** That's the separate, known CM5 panel-driver issue. Warm reboots light it far more reliably than cold boots: `ssh root@clockworkpi.local 'reboot'`. Keep the system updated for panel-driver fixes. See [TROUBLESHOOTING](TROUBLESHOOTING.md#the-panel-driver-black-screen-but-it-does-boot).
