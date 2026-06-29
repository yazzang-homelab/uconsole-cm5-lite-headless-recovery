# Troubleshooting & Field Notes

Practical notes that don't fit the linear recovery but cost real time if you don't know them.

## Reading the LEDs correctly

The green LED you see on the outside of the uConsole is the **power LED** (power present). It is **not** the Raspberry Pi **ACT** (SD activity) LED — that one is on the compute module, hidden inside the shell. Consequences:

- "The green LED never blinks" tells you **nothing** about boot progress. Do not conclude the device is dead from this.
- EEPROM-flash blink patterns (rapid blink = writing) happen on the **ACT** LED you can't see. So during the `recovery.bin` EEPROM flash you may observe **no visible change** on the power LED even though it's working.
- The reliable "is it alive?" signal is **heat**: a warm chassis after 1–2 minutes means the SoC is executing.

## Green Light of Death (GLOD)

A dim, stuck power LED that won't respond is the community's "Green Light of Death," typically caused by an unclean hard reset.

- **To shut down with a black screen: double-tap the power button.** This triggers a clean shutdown without needing the display.
- **Avoid repeated long-press hard resets.** They are what tends to induce the stuck state.
- If you do hit GLOD: fully remove power (and battery, if fitted), wait, and re-power.

## Blind reboot (when it *does* boot but the panel is black)

If the system is up (on the network, SSH works) but the LCD is black, the cleanest fix is simply:

```bash
ssh root@clockworkpi.local 'reboot'
```

Warm reboots initialise the CM5 panel far more reliably than cold boots. If you have no SSH yet but the OS is up, the community "blind reboot" key sequence on the device is: **press the power button once → press the Down-arrow once → press Enter** (this drives the on-screen power menu you can't see, selecting *Restart*). Wait until you're sure it has reached the desktop/login before trying it.

## The panel driver (black screen but it *does* boot)

The CM5 panel driver (`panel-cwu50`) is still maturing. Even on a correct image you may see:

```
panel-cwu50 ...: old panel, cycling the reset pin
drm-rp1-dsi ...: rp1dsi_bind succeeded
```

`rp1dsi_bind succeeded` means the panel came up. If it didn't this boot, a **warm reboot** usually fixes it. Keep the OS updated (`apt full-upgrade`) for ongoing panel fixes. This panel issue is **independent** of the boot problems in this guide — if you can SSH in, the recovery worked.

## Unreliable USB card readers

A flaky USB SD reader will mimic a dead card and waste hours. Symptoms seen during this recovery on one reader:

```
usb 1-1: reset high-speed USB device ...        # reset loop
... device offline error, dev sdb ...           # card drops mid-operation
... Unit Attention ... medium may have changed   # re-enumeration
```

Mitigations, in order of effectiveness:

1. **Use a different, known-good reader.** This was the single fix that gave stable reads/writes. A simple Genesys-Logic microSD reader was rock-solid where a multi-card reader kept dropping.
2. Use a **rear/motherboard USB port**, not a front-panel port or a hub (more stable power, especially on small-form-factor PCs).
3. As a stopgap, you can sometimes re-enumerate a dropped device without replugging:
   ```bash
   echo 0 | sudo tee /sys/bus/usb/devices/<port>/authorized
   sleep 2
   echo 1 | sudo tee /sys/bus/usb/devices/<port>/authorized
   ```
   …but this is a band-aid. If a reader drops repeatedly, **replace it** before doing any writes — a write interrupted by a drop can corrupt the boot partition.

Important: two *different* SD cards failing identically in the *same* reader means the **reader** is the problem, not the cards.

## "I flashed Trixie / the uConsole image and it still won't boot"

That's expected if only Cause B was addressed. The two silent killers are:

- **Cause A** — EEPROM still can't see the SD on cold boot (fix the EEPROM, [ROOT-CAUSE](ROOT-CAUSE.md#cause-a--the-cm5-lite-bootloader-eeprom-cant-see-the-sd-card)).
- **Cause C** — `firstboot` hangs headless (remove it from `cmdline.txt`, [ROOT-CAUSE](ROOT-CAUSE.md#cause-c--the-firstboot-init-hook-hangs-on-a-headless-unit)).

Check on the host: is `recovery.bin` still named `recovery.bin` (EEPROM never ran)? Does `cmdline.txt` still contain `init=…firstboot` and is `/var/log/journal` empty (firstboot hung)?

## Verifying EEPROM success after the fact

Two independent confirmations:

1. On the SD (host): `recovery.bin` has been renamed to `RECOVERY.000` → the BootROM consumed it.
2. Over SSH (booted): `vcgencmd version` prints a bootloader date **≥ 2025-01-06** (ideally a 2025/2026 date).

## Power supply

The CM5 has higher peak current draw than the CM4. If you see boot loops or brownouts, ensure charged 18650 cells and/or a strong USB-C PD source (20 W+). Underpowering can look like a boot failure.
