# Bootloader firmware update — necessary, but NOT a replacement for `SD_QUIRKS`

> **Correction (2026-06-30).** An earlier version of this page claimed that a
> recent bootloader firmware fixes SD detection at the firmware level, "after
> which `SD_QUIRKS` is no longer needed." **That was wrong for this hardware,
> and following it caused a regression.** See
> [the postmortem below](#why-sd_quirks-must-stay-2026-06-30-postmortem).
> The corrected guidance: update the firmware *and* keep `SD_QUIRKS=1` pinned.

The original recovery (cause **A**) used an EEPROM config with `SD_QUIRKS=1` /
`SD_BOOT_MAX_RETRIES` to dodge the CM5 Lite cold-boot SD-detection timing bug.
Updating to a recent `firmware-2712` release is still worth doing — it carries
the broader SD fixes and other bootloader improvements — but on this specific
CM5 Lite + SD-card combination it does **not** remove the need for `SD_QUIRKS=1`.
Treat the firmware update as hygiene, not as a cure that lets you drop the quirk.

If your uConsole **booted fine, then a reboot dropped it back into "green LED,
black screen, never joins the network,"** the most likely cause is that an
EEPROM config *without* `SD_QUIRKS=1` got flashed — either by hand or by
`rpi-eeprom-update -a` resetting the config to its default (see the warning
under Option 1). The fix is to re-flash an EEPROM image that **includes**
`SD_QUIRKS=1`.

> **Do this while the device is healthy and reachable.** The best time to touch
> the bootloader is *before* it strands you — not after. If you can SSH in, use
> Option 1 (with the config caveat); if it's already stranded, use Option 2.

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

> ⚠️ **`rpi-eeprom-update -a` resets the EEPROM config to the firmware default,
> which does NOT contain `SD_QUIRKS=1`.** On this hardware that is exactly how a
> healthy unit gets re-stranded on the next cold boot. After flashing, **re-apply
> the quirk before you trust a power-off:**
>
> ```bash
> # Re-pin our config on top of the freshly flashed firmware
> sudo rpi-eeprom-config --edit      # add SD_QUIRKS=1, BOOT_ORDER=0xf461,
>                                     # SD_BOOT_MAX_RETRIES=5, NET_INSTALL_AT_POWER_ON=0
> # (or non-interactively)
> sudo rpi-eeprom-config --apply scripts/uconsole-eeprom.txt
> sudo reboot
> ```
>
> Then verify (see below) that `rpi-eeprom-config` shows `SD_QUIRKS=1`.

After it comes back:

```bash
vcgencmd bootloader_version     # should show the new (recent) date
rpi-eeprom-update               # "BOOTLOADER: up to date"
rpi-eeprom-config | grep SD_QUIRKS   # MUST print SD_QUIRKS=1
```

The OS tooling handles signing and verification for you. This is the right path
whenever the device is bootable — but on this CM5 Lite it is only safe if you
re-apply `SD_QUIRKS=1` afterward, because the plain `-a` flash drops it.

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

## Why `SD_QUIRKS` must stay (2026-06-30 postmortem)

`SD_QUIRKS=1` slows the SD card to SDR mode in the bootloader to dodge an
init-timing bug. We *assumed* recent firmware fixed that timing properly and that
a clean update would boot reliably without the quirk. **Field evidence says
otherwise on this hardware.**

What happened, in order:

1. **First recovery:** flashed an EEPROM config with `SD_QUIRKS=1` → reliable
   cold boot. Good.
2. **"Permanent fix" attempt:** updated to the latest firmware (`2026/06/17`) and,
   trusting the assumption above, rebuilt the EEPROM config **without**
   `SD_QUIRKS` (just `BOOT_ORDER` + `SD_BOOT_MAX_RETRIES=2`). It booted, and ran
   fine for over a day.
3. **Regression:** a routine reboot dropped the unit straight back into "green
   LED, black screen, never joins the network." Mounting the SD on another Linux
   box showed **both filesystems `fsck`-clean, `cmdline.txt` intact (no
   `firstboot`), `root=PARTUUID` matching, kernel + DTBs + overlay all present**
   — i.e. the SD was perfect and the OS never even started. The failure was
   purely the bootloader not latching the SD on cold boot.
4. **Fix:** rebuilt the EEPROM image on the **same** `2026/06/17` firmware, this
   time **with `SD_QUIRKS=1`** (and `SD_BOOT_MAX_RETRIES=5`), re-flashed via
   `recovery.bin`. Cold boot became reliable again. Verified on the booted device:
   `rpi-eeprom-config` shows `SD_QUIRKS=1` and `vcgencmd bootloader_version`
   reports `2026/06/17` with an `update-time` matching the new image.

**Takeaway:** for this CM5 Lite + SD-card combination, `SD_QUIRKS=1` is
load-bearing independent of firmware version. The underlying issue is most likely
a marginal SD interface that the stock bootloader timing doesn't reliably drive
on cold boot; the quirk is what makes it dependable. Updating the firmware is
still worthwhile, but **never ship an EEPROM config that omits `SD_QUIRKS=1`.**

The correct config (also in `scripts/uconsole-eeprom.txt`):

```ini
[all]
BOOT_UART=1
BOOT_ORDER=0xf461
SD_QUIRKS=1                  # load-bearing on this hardware — do NOT remove
SD_BOOT_MAX_RETRIES=5        # cold-boot insurance
NET_INSTALL_AT_POWER_ON=0    # fixed-SD device: never divert to network install
```
