# Permanent fix — update the bootloader firmware (stop the cold-boot failure from recurring)

The original recovery (cause **A**) used an EEPROM config with `SD_QUIRKS=1` /
`SD_BOOT_MAX_RETRIES=2` to *work around* the CM5 Lite cold-boot SD-detection bug.
That gets you booting again, but it is a **mitigation, not a cure**: the
underlying bug lives in old bootloader firmware, and a later reboot can drop you
straight back into "green LED, black screen, never joins the network."

If your uConsole **booted fine, then a reboot bricked it again**, this is almost
certainly what happened. The durable fix is to flash a **recent bootloader
firmware** — recent `firmware-2712` releases fix SD detection at the firmware
level, after which `SD_QUIRKS` is no longer needed.

> **Do this while the device is healthy and reachable.** The best time to update
> the bootloader is *before* it strands you — not after. If you can SSH in, the
> one-liner below is all it takes.

---

## Option 1 — from the running OS (preferred, safest)

If the device boots and you can reach a shell:

```bash
# See current vs available bootloader
rpi-eeprom-update

# Flash the latest and reboot
sudo rpi-eeprom-update -a
sudo reboot
```

After it comes back:

```bash
vcgencmd bootloader_version     # should show the new (recent) date
rpi-eeprom-update               # "BOOTLOADER: up to date"
```

The OS tooling handles signing and verification for you. This is the right path
whenever the device is bootable — it avoids touching the SD offline at all.

---

## Option 2 — offline, via `recovery.bin` (when it won't boot)

Same BootROM mechanism as the original recovery, but pointed at the **latest**
firmware instead of the workaround config. Run on any Linux box with the SD's
FAT boot partition mounted.

`scripts/build-eeprom.sh` now produces all three required files:

```bash
./scripts/build-eeprom.sh ./out
# ./out/recovery.bin
# ./out/pieeprom.upd
# ./out/pieeprom.sig   <-- recent recovery.bin REFUSES to flash without this
```

Copy **all three** onto the FAT boot partition, then power on **once**:

1. The BootROM runs `recovery.bin`, verifies `pieeprom.upd` against
   `pieeprom.sig`, and flashes the EEPROM — **no OS or display required.**
2. On success it renames `recovery.bin` → `RECOVERY.000` (your proof it ran) and
   typically **halts at a green screen.** The CM5 does *not* always chain
   straight into the OS in the same power cycle.
3. **Power-cycle a second time.** *This* boot runs the OS with the new firmware.

> A common trap: the first power-on only flashes the EEPROM and stops. If you
> pull the card or give up after one boot, it looks like nothing happened — but
> `RECOVERY.000` on the boot partition confirms the flash succeeded. Just boot
> it once more.

### Confirming offline that the flash happened

Re-mount the SD's boot partition on another machine:

```
recovery.bin   →   RECOVERY.000     # BootROM consumed it = it flashed
pieeprom.upd / pieeprom.sig         # may remain (inert) or be auto-removed
```

And the rootfs tells you whether the OS *then* booted: if the newest files under
`/var/lib/systemd/` (e.g. `random-seed`) and `/var/log/` are **older than the
flash**, the OS has not booted yet — do the second power-cycle.

---

## Why `SD_QUIRKS` becomes unnecessary

`SD_QUIRKS=1` slows the SD card to SDR mode in the bootloader to dodge the
init-timing bug. Recent firmware fixes that timing properly, so a clean update
boots reliably **without** the quirk. We still keep `SD_BOOT_MAX_RETRIES=2` as
cheap insurance and `BOOT_ORDER=0xf461` to guarantee SD-first — but the quirk is
no longer load-bearing. (See `scripts/uconsole-eeprom.txt` for the annotated
config.)

A reasonable "latest firmware" config is simply:

```ini
[all]
BOOT_UART=1
BOOT_ORDER=0xf461
SD_BOOT_MAX_RETRIES=2
NET_INSTALL_AT_POWER_ON=0    # fixed-SD device: never divert to network install
```
