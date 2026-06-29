# Root Cause Analysis

This is the reasoning trail — how a "green light, black screen, dead on the network" uConsole CM5 Lite was diagnosed down to three stacked software causes, and why the common guesses (bad assembly, bad CM5 adapter, dead panel) were ruled out.

## The starting symptom set

- Power LED (green) lights when powered on; internal LCD never shows an image.
- Micro-HDMI output also blank.
- Device **never joins Wi-Fi** → no LAN presence, no SSH, no mDNS.
- **Chassis gets warm** after a minute or two.
- Re-flashing the SD with a different OS image did not fix it.

## Ruling out hardware first

It is tempting to blame assembly, the CM5-into-CM4 adapter board, or a dead DSI panel. The decisive observations against that:

1. **The chassis gets warm.** That means the SoC is powered and executing — the CM5 module, the adapter, and the carrier board are delivering power and clocking the CPU. A fatal adapter/assembly fault generally means the CPU never runs at all.
2. **The green LED is the *power* LED**, not the SD-activity (ACT) LED. On the uConsole the ACT LED is on the compute module under the shell, so "the green LED never blinks" tells you **nothing** about boot progress — a very common source of misdiagnosis.
3. Community consensus: *if the device produces output on an external monitor, the adapter is fine and the problem is software.* The corollary — no output anywhere **plus** a warm CPU — points at **boot firmware / OS**, not silicon.

Conclusion: the hardware is almost certainly fine. The CPU is trying to boot and failing before it can light the panel or bring up Wi-Fi.

---

## Cause A — The CM5 Lite bootloader EEPROM can't see the SD card

The CM5 (especially the **Lite**, which has no eMMC and *must* boot from SD) shipped with bootloader firmware that has a **known SD-card detection bug on cold boot**. The bootloader intermittently fails to initialise the SD card during the `BOOT_ORDER` phase, so it never loads `start.elf`/the kernel — you get power, a warm idle-ish SoC, and nothing else.

Key facts:
- Affected firmware is **older than 2025-01-06**; you need a newer `firmware-2712` EEPROM.
- The fix is an EEPROM **config** that:
  - puts **SD first** in the boot order,
  - **retries** the SD card,
  - and **slows the SD card down** in the bootloader (SDR mode) to dodge the init-timing bug.

```ini
[all]
BOOT_UART=1
# Switch off PMIC outputs on HALT
POWER_OFF_ON_HALT=1
# SD -> NVMe -> USB -> Network
BOOT_ORDER=0xf461
# Retry the SD card before falling through
SD_BOOT_MAX_RETRIES=2
# Slow the SD card (SDR) in the bootloader — works around the init-timing bug
SD_QUIRKS=1
```

`SD_QUIRKS=1` and `SD_BOOT_MAX_RETRIES=2` are the two settings that actually defeat the detection bug; `BOOT_ORDER=0xf461` just guarantees SD is tried first.

### The chicken-and-egg problem (and its solution)

The "obvious" way to change the EEPROM — `sudo rpi-eeprom-config -e` — requires a **booted OS and a working console.** You have neither. The escape hatch is the Pi BootROM's **`recovery.bin` mechanism**, which runs *before* the EEPROM boot order matters and reflashes the EEPROM from files on the SD's FAT boot partition — **no OS, no display required.** You build `recovery.bin` + a configured `pieeprom.upd` on another machine and drop them on the boot partition. See [`scripts/build-eeprom.sh`](../scripts/build-eeprom.sh).

### How we confirmed it actually flashed

After the first boot, mounting the SD on another machine showed:

```
recovery.bin   →   RECOVERY.000      # BootROM consumed the recovery file (= it ran)
```

and afterward, over SSH, `vcgencmd version` reported a **2026-era** bootloader date — i.e. the EEPROM really was updated, well past the 2025-01-06 threshold. That alone moved the device from "never reads SD" to "boots."

---

## Cause B — A generic Raspberry Pi OS image has no uConsole drivers

The first SD had been written with **stock Raspberry Pi OS Lite**. Mounting it revealed a completely ordinary `config.txt` — `dtoverlay=vc4-kms-v3d`, the usual CM5 bits — and **no uConsole overlay at all.** That image has no driver for the uConsole's DSI panel, its keyboard, or its Wi-Fi front-end, so even if it boots you get a black screen and no Wi-Fi.

A **uConsole-specific image** is identifiable by its `config.txt`, which contains:

```ini
[pi5]
dtoverlay=clockworkpi-uconsole-cm5
dtoverlay=vc4-kms-v3d-pi5,cma-384
```

and a `kernel_2712.img` plus the `bcm2712-rpi-cm5l-cm4io.dtb` (CM5 **Lite** on the CM4 I/O carrier) on the boot partition. Use the community "REX" Debian Trixie/Bookworm builds or an equivalent uConsole image.

> Note: switching to the correct image is necessary but **not sufficient** — see Cause C. This is why people report "I flashed the uConsole image / Trixie and it *still* didn't boot."

---

## Cause C — The `firstboot` init hook hangs on a headless unit

This is the cause that ties the whole thing together and is the least documented.

Modern Raspberry Pi images (including uConsole images provisioned via Raspberry Pi Imager) boot the **first time** with a special kernel argument in `cmdline.txt`:

```
init=/usr/lib/raspberrypi-sys-mods/firstboot
```

Instead of starting `systemd`, the kernel runs the `firstboot` script, which is supposed to expand the filesystem, apply Imager customisation, **remove `init=…firstboot` from `cmdline.txt`, and reboot** into the real OS.

On a **headless** unit whose console/display isn't up, this hook can **hang indefinitely**. When it hangs:

- `systemd` never starts → no `NetworkManager` → **no Wi-Fi, no SSH, no mDNS.**
- Nothing is written to the journal → the rootfs logs stay **empty / frozen at the image build date.**
- The device sits warm and silent forever.

### How we confirmed it

Mounting the rootfs after a "failed" boot showed:

- `cmdline.txt` **still contained** `init=…/firstboot` (so firstboot never completed its job of removing itself), and
- `/var/log/journal/` was **empty** and every log file was dated the image's build day — proof the OS had **never** reached `systemd` on this card.

### The fix

Delete just the `init=…firstboot` token from `cmdline.txt` so the kernel boots **straight into `systemd`**:

```diff
- ... rootwait quiet init=/usr/lib/raspberrypi-sys-mods/firstboot fbcon=rotate:1 ...
+ ... rootwait quiet fbcon=rotate:1 ...
```

Because we provision SSH, Wi-Fi and the SSH key ourselves (see Cause-fix integration below), there is nothing `firstboot` needed to do. The very next boot brought up `systemd` → `NetworkManager` → Wi-Fi → SSH, and the device answered on `clockworkpi.local`.

(Trade-off: removing `firstboot` also skips its automatic root-filesystem expansion. Expand it yourself after first boot — many uConsole images also ship their own resize service, so check `df -h /` first.)

---

## Why all three had to be fixed together

- Fix **A** alone: the bootloader can finally read the SD — but a generic image (**B**) or a hung `firstboot` (**C**) still leaves you with a black screen and no network.
- Fix **B** alone: correct drivers — but the bootloader still can't reach the SD (**A**), or `firstboot` still hangs (**C**).
- Fix **C** alone: `systemd` would start — but only if the bootloader could load the kernel (**A**) from a driver-correct image (**B**).

The reliable recovery applies **A + B + C in one pass** on the SD, then boots. See [STEP-BY-STEP](STEP-BY-STEP.md).

---

## Diagnostic cheatsheet

| Observation | Tells you |
|---|---|
| Chassis warm, green LED on, nothing else | CPU runs; failure is in boot firmware/OS, not hardware. |
| `recovery.bin` renamed to `RECOVERY.000` on the SD after a boot | BootROM ran the EEPROM recovery (Cause A addressed). |
| `vcgencmd version` shows a date ≥ 2025-01-06 (over SSH) | EEPROM is new enough; SD-detect bug fixed. |
| `config.txt` lacks `clockworkpi-uconsole-*` overlay | Wrong (generic) image — Cause B. |
| `cmdline.txt` still has `init=…firstboot` **and** rootfs logs are empty | `firstboot` hung; OS never reached `systemd` — Cause C. |
| Device **is** on the network but screen black | Only the panel driver — just SSH in and `sudo reboot`. |

---

## References

- ClockworkPi forum: "EEPROM config and the CM5 lite", "Bookworm 6.12.y for the uConsole and DevTerm", "New uConsole build, CM5 lite, screen remains black", "uConsole + CM5 Green Led ON".
- `raspberrypi/rpi-eeprom` (GitHub) — `firmware-2712/` EEPROM images, `recovery.bin`, and `rpi-eeprom-config`. Issue #670: "[CM5 Lite] SD card is not detected on bootloader phase."
- Raspberry Pi docs: bootloader configuration (`BOOT_ORDER`, `SD_QUIRKS`, `SD_BOOT_MAX_RETRIES`), and the EEPROM update/recovery flow.
- `ak-rex/ClockworkPi-pi-gen` — Trixie image build pipeline for DevTerm/uConsole.
