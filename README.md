# ClockworkPi uConsole CM5 Lite — Headless Boot Recovery

**Fixing the "green LED on, black screen, won't boot, never appears on the network" problem on a ClockworkPi uConsole with a Compute Module 5 Lite — entirely headless (no monitor, no micro-HDMI, no working internal LCD).**

This repository documents a real, end-to-end recovery: the exact symptoms, how each root cause was isolated, and a reproducible fix using only another Linux machine and an SD card reader. If your uConsole CM5 (Lite) powers on, the panel stays black, and it never shows up on your network so you can't even SSH in, this guide is for you.

---

## TL;DR

A uConsole CM5 Lite that shows only a power LED and a black screen, and that **never joins the network**, is almost never a hardware/assembly fault. In this case there were **three independent software-level causes stacked on top of each other**:

| # | Root cause | Fix |
|---|-----------|-----|
| **A** | CM5 Lite **bootloader EEPROM fails to detect the SD card** on cold boot (firmware older than 2025-01-06; missing `SD_QUIRKS` / SD-first `BOOT_ORDER`). | Flash an updated EEPROM via `recovery.bin` + a config containing `SD_QUIRKS=1`, `BOOT_ORDER=0xf461`, `SD_BOOT_MAX_RETRIES=2`. **`SD_QUIRKS` is a workaround — for a fix that survives reboots, flash the *latest* firmware: see [FIRMWARE-UPDATE](docs/FIRMWARE-UPDATE.md).** |
| **B** | A **generic Raspberry Pi OS image** was flashed, which has none of the uConsole drivers (panel, keyboard, Wi-Fi device tree). | Flash a **uConsole-specific image** (one that ships `dtoverlay=clockworkpi-uconsole-cm5`). |
| **C** | The image's **`init=…/raspberrypi-sys-mods/firstboot` hook hangs forever** when there is no working console, so `systemd`, networking and SSH never start. | **Remove the `init=…firstboot` token from `cmdline.txt`** and let it boot straight into `systemd`. |

Because the screen is black, you fix all of this **offline, by mounting the SD card on another Linux box**, then boot once and connect over SSH (found via mDNS `clockworkpi.local`).

> **The single most under-documented cause is C.** Even with a correct EEPROM and a correct uConsole image, an Imager-provisioned `firstboot` hook will hang silently on a headless unit and leave you with an empty-log, no-network device that *looks* dead.

---

## Symptoms (what this fixes)

- Power LED (green) turns on; **internal LCD stays black**. Micro-HDMI also shows nothing.
- The device **never appears on the LAN** — no DHCP lease you can find, no `ping`, no SSH.
- The chassis **gets warm** (the CPU is actually running — a key clue it is *not* dead).
- Flashing a different OS image (even "Trixie") does not help on its own.
- Pressing the power button does nothing useful because nothing finished booting.

If your device **does** appear on the network but the screen is black, you only have a panel-driver issue — skip to [TROUBLESHOOTING](docs/TROUBLESHOOTING.md#the-panel-driver-black-screen-but-it-does-boot); you can just SSH in and `sudo reboot` (warm boots light the panel far more reliably than cold boots).

---

## What you need

- The uConsole CM5 (Lite), its SD card, and **a second computer running Linux** (a Raspberry Pi, a PC, a VM, anything with `apt`/`git` and the ability to mount ext4).
- A **reliable USB SD card reader.** (See the [hardware note](docs/TROUBLESHOOTING.md#unreliable-usb-card-readers) — a flaky reader will waste hours.)
- Your Wi-Fi SSID + passphrase, and (recommended) an SSH public key.

You do **not** need a monitor, a micro-HDMI adapter, or a working LCD.

---

## The fix in five steps

1. **Build the EEPROM update** (`recovery.bin` + `pieeprom.upd`) with the SD-quirk config — [`scripts/build-eeprom.sh`](scripts/build-eeprom.sh).
2. **Flash a uConsole-specific OS image** to the SD card (Raspberry Pi Imager → *Use custom*).
3. **Inject everything headless** onto the SD — EEPROM files, `ssh`, Wi-Fi, your SSH key, and the `firstboot` removal — [`scripts/inject-headless.sh`](scripts/inject-headless.sh).
4. **Boot the uConsole.** First boot flashes the EEPROM (it may power off on halt — power it back on). Subsequent boot goes straight into the OS.
5. **Find it and log in:** `ssh root@clockworkpi.local` (or scan your LAN). Then optionally add Tailscale, change passwords, etc.

Full detail: **[docs/STEP-BY-STEP.md](docs/STEP-BY-STEP.md)**.
Why each step is needed and how the causes were diagnosed: **[docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md)**.
LED reading, blind reboot, GLOD, flaky readers: **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**.

---

## ⚠️ Safety / security notes

- **Never hard-reset (long power-press) repeatedly.** The CM5 can enter a "Green Light of Death" (dim, stuck LED) state. Prefer a **double-tap** to shut down. See [TROUBLESHOOTING](docs/TROUBLESHOOTING.md#green-light-of-death-glod).
- All commands here are run against **your own device on your own network.**
- The scripts use **placeholders** (`WIFI_SSID`, `WIFI_PSK`, `/dev/sdX`, your public key). Fill them in locally; **do not commit real secrets.**
- Prefer **SSH key authentication** and Tailscale's **browser-based login** over copying auth keys around.

---

## Credits & references

- ClockworkPi forum — CM5 Lite EEPROM / black-screen threads.
- `raspberrypi/rpi-eeprom` — bootloader images and `rpi-eeprom-config`.
- The community "REX" Debian Trixie / uConsole images and the `ak-rex/ClockworkPi-pi-gen` build pipeline.

See [docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md#references) for direct links.

## License

MIT — see [LICENSE](LICENSE).
