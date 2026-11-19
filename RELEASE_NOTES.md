# INAV Servo Support Assistant 1.2.0

## Downloads

| Mac | File |
|---|---|
| Apple Silicon (M1/M2/M3/M4) | `INAV-Servo-Support-Assistant-1.2.0-macOS-arm64.zip` |
| Intel | `INAV-Servo-Support-Assistant-1.2.0-macOS-x86_64.zip` |

Requires macOS 13 (Ventura) or newer.

> **First launch:** the app is ad-hoc signed, not notarized, so macOS may block it. Right-click the app → **Open**, or run
> `xattr -dr com.apple.quarantine "INAV Servo Support Assistant (arm64).app"` (use the x86_64 name for the Intel build).

## What's new in 1.2.0

- **Workflow order in the action bar** – *Review & Apply…* now comes first, followed by *Test Build* (Review & Apply → Test Build). The Test Build tooltip says that it builds the files on disk, i.e. including the servo changes once they are applied.
- **Target folder backups** – *Back up target folder first* in the Review & Apply sheet (on by default, remembered) copies the complete target folder to `<inav>/.servo-backups/<TARGET>/<date-time>` before the changes are written. *More → Back up target now*, *Restore target backup* (list by date; the current state is backed up before restoring) and *Show backups in Finder*. Backups live outside `src/main/target`, so CMake does not see them as duplicate targets, and are ignored by git.
- **Refresh button** above the target list – re-reads `src/main/target` (new, renamed or deleted target folders) and keeps the current target and pad selection.

---

# INAV Servo Support Assistant 1.1.0

## What's new in 1.1.0

- **Branch / tag picker when cloning** – the clone dialog loads all branches and tags of the repository (`git ls-remote`, nothing else is downloaded) into a searchable list with *Branches* / *Tags* tabs. `master` first, then release and maintenance branches newest first; tags newest first with each release above its RCs. A ✓ / ⚠ next to the field shows whether the typed name exists on the remote; any name can still be typed by hand.
- **AT32F435/437 targets work** – the targets use `target_at32f43x_xGT7` / `target_at32f43x_xMT7`, which the app did not recognise, so all 14 AT32 boards showed as unsupported. Other package variants fall back to the family automatically.
- **STM32G473 support** (`target_stm32g473xe`) for inav checkouts that contain an STM32G4 port (`drivers/timer_def_stm32g4xx.h`, `timer_stm32g4xx.c`). Timer AF table and DMAMUX handling as on H7; SBUS works on every UART (internal inversion). Checkouts without the port show a clear message.
- README: download section, updated workflow (motor disabling, config.c, target copy, DFU flashing) and screenshots.

---

# INAV Servo Support Assistant 1.0.0

First release of **INAV Servo Support Assistant** – a native macOS app (SwiftUI + Metal) that adds servo outputs on the UART and LED-strip pads of inav flight-controller targets.

## Features

**Source & targets**
- Open an existing inav checkout or clone one from GitHub; recent sources and a start screen
- Pick any target from `src/main/target` (STM32F405/F411/F427/F722/F745/F765/H743, AT32F435/437, STM32G473 with a G4 port)

**Servo candidates**
- UART and LED-strip pads checked against the MCU's timer alternate-function tables (embedded ST datasheet tables for F4, inav's tables for F7/H7/AT32) and against what inav's `DEF_TIM()` can compile
- Conflict checks: timers driving motors (the clashing motor outputs are disabled, with a motor 1…n overview), LED strip, softserial, ADC, channels already in use
- **Shared** mode (pad is UART *or* servo) and **Dedicated** mode (servo only, UART removed)
- Default port settings in `config.c` / `target.h` (e.g. `SERIALRX_UART`) are moved off converted UARTs – prevents the `portConfigs[-1]` corruption of hand-made edits

**Planning & applying**
- Remaining-serial-port planner for receiver (CRSF/ELRS, SBUS), GPS and VTX (SmartAudio/Tramp, MSP DisplayPort)
- Diff preview of `target.c`, `target.h`, `config.c`; automatic backups and one-click revert
- Apply in place or as a new target copy (`<TARGET>_SERVO`) that leaves the original untouched
- Export / apply `.patch` files, commit the target to a git branch
- Paste-ready CLI commands for after flashing (`feature PWM_OUTPUT_ENABLE`, `serial …`, receiver settings)

**Build & flash**
- Test Build with one shared ARM toolchain cache for all inav checkouts
- Flash via DFU – the flight controller is rebooted into DFU over USB (inav CLI `dfu`), no BOOT button needed

**Insight**
- Metal-rendered GPIO map with board pad names (S1, M5, TX6, LED …)
- DMA check for STM32F4/F7 (DShot motors, LED strip, ADC; per-channel and burst DMA)

## Notes
- Always check motor order and direction in the configurator before the first flight after changing outputs.
- Servo outputs only start when "Enable motor and servo output" is on (`feature PWM_OUTPUT_ENABLE`).

Licensed under GPL-3.0 – see [LICENSE](LICENSE). Details in the [README](README.md).
