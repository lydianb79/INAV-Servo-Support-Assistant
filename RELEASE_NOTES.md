# INAV Servo Support Assistant 1.0.0

First release of **INAV Servo Support Assistant** – a native macOS app (SwiftUI + Metal) that adds servo outputs on the UART and LED-strip pads of inav flight-controller targets.

## Downloads

| Mac | File |
|---|---|
| Apple Silicon (M1/M2/M3/M4) | `INAV-Servo-Support-Assistant-1.0.0-macOS-arm64.zip` |
| Intel | `INAV-Servo-Support-Assistant-1.0.0-macOS-x86_64.zip` |

Requires macOS 13 (Ventura) or newer.

> **First launch:** the app is ad-hoc signed, not notarized, so macOS may block it. Right-click the app → **Open**, or run
> `xattr -dr com.apple.quarantine "INAV Servo Support Assistant (arm64).app"` (use the x86_64 name for the Intel build).

## Features

**Source & targets**
- Open an existing inav checkout or clone one from GitHub; recent sources and a start screen
- Pick any target from `src/main/target` (STM32F405/F411/F427/F722/F745/F765/H743, AT32F435/437)

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
