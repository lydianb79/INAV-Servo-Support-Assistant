<p align="center"><img src="AppIcon.png" width="160" alt="App icon"></p>

# INAV Servo Support Assistant (macOS)

A native macOS app (SwiftUI + Metal) that adds **servo outputs on UART and LED-strip pads** to an inav
flight-controller target. It reads the target's `target.h` / `target.c`, checks every UART pin and the
LED pad against the MCU's timer alternate-function table, shows which pads are possible candidates,
lets you choose pads and timer channels, checks which of the remaining UARTs can still take a
receiver, GPS and VTX, and then edits `target.c` / `target.h` (and `config.c` where needed) – in place
or as a new target copy. It can also test-build the firmware and flash it via DFU without pressing the
BOOT button.

## Download

Ready-built apps are on the [Releases](https://github.com/lydianb79/INAV-Servo-Support-Assistant/releases) page:

| File | Mac |
|------|-----|
| `INAV-Servo-Support-Assistant-1.0.0-macOS-arm64.zip`  | Apple Silicon (M1 and newer) |
| `INAV-Servo-Support-Assistant-1.0.0-macOS-x86_64.zip` | Intel |

Unzip and move the app to *Applications*. Requires macOS 13 (Ventura) or newer. The app is only ad-hoc
signed, so on first launch macOS blocks it: right-click the app → *Open* → *Open* (or *System Settings →
Privacy & Security → Open Anyway*). Alternatively: `xattr -dr com.apple.quarantine "INAV Servo Support Assistant (arm64).app"`.

For *Test Build* you need `cmake` (`brew install cmake`), for flashing `dfu-util` (`brew install dfu-util`).
See [RELEASE_NOTES.md](RELEASE_NOTES.md) for what's in each version.

## Build & run

Requires macOS 13 (Ventura) or newer and Xcode *or* the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/lydianb79/INAV-Servo-Support-Assistant.git
cd INAV-Servo-Support-Assistant
./build_app.sh --run          # builds "INAV Servo Support Assistant.app" here and launches it
```

Other options:
* `./build_app.sh --arch arm64` / `./build_app.sh --arch x86_64` – separate Apple Silicon / Intel builds, named
  `INAV Servo Support Assistant (arm64).app` / `(x86_64).app`, each also zipped as
  `INAV-Servo-Support-Assistant-<version>-macOS-<arch>.zip`
* `./build_app.sh --universal` – one app with both architectures (needs full Xcode)
You can also open `Package.swift` in Xcode and press ⌘R.

The Metal shaders are compiled at runtime from source (`MTLDevice.makeLibrary(source:)`),
so the separate `metal` compiler from full Xcode is **not** needed.

## Workflow

1. **Source** – at launch a start screen offers *Continue* with the last source, the list of recent
   sources, *Open other inav folder…* and *Clone…*. While the app is open the same choices are in the
   **Source** toolbar menu, the **Change** menu in the sidebar header, and the File menu
   (⌘O open, ⇧⌘N clone, ⇧⌘0 start screen). Cloning again proposes a free folder name (`inav-2`, …),
   so an existing checkout is never overwritten.
2. **Target** – choose a board from `src/main/target/` in the sidebar (filter by name or MCU).
3. **Analysis** – the app shows
   * a Metal-rendered GPIO map (ports × pins): green = UART pad that can be a servo,
     blue = existing motor/servo output, purple = UART without usable timer, orange pulse = selected,
     greyed = motor output that your selection disables; board pad names (S1, M3, TX6, LED …) are drawn on
     the pads; hover for details, click a green pad to select it,
   * *How it works* – a short explanation of the shared / dedicated modes,
   * the **Motor outputs** strip (motor 1, 2, 3, 4 …) showing which motors stay usable,
   * one card per UART / LED pad with the timer options for TX and RX, all detected conflicts and the
     rejected options with the reason.
4. **Select** – tick UART(s), the LED pad or individual pads, pick the timer channel and the mode:
   * **UART shared** – UART stays defined. inav's `checkPwmTimerConflicts()` skips the timer output
     while the UART has a function in the Ports tab, so the pad works as UART *or* servo.
   * **UART dedicated** – the `USE_UARTn` / `UARTn_*` defines are commented out and `SERIAL_PORT_COUNT`
     is reduced. Required for UART1, which inav's runtime check does not cover.
   * **LED shared** – `TIM_USE_SERVO` is added next to `TIM_USE_LED`: servo while the LED Strip
     feature is off (configurator: *Configuration → LED Strip*, or CLI `feature -LED_STRIP`), LED strip
     output when it is on.
   * **LED dedicated** – `TIM_USE_LED` is replaced by `TIM_USE_SERVO`, `USE_LED_STRIP` / `WS2811_*`
     are commented out and `FEATURE_LED_STRIP` is removed from `DEFAULT_FEATURES`.

   If the chosen timer also drives motors, those motor outputs are disabled (see *How candidates are
   determined*); the Motor outputs strip updates immediately.
5. **Remaining serial ports** – choose the receiver (CRSF/ELRS or SBUS), GPS and VTX
   (SmartAudio/Tramp or MSP DisplayPort). The table lists every UART and softserial port with its
   state after your selection and ✓ / ⚠ / ✗ per peripheral, and a suggested assignment is computed:
   * CRSF/ELRS, GPS, MSP DisplayPort need TX + RX (RX only → ⚠ no telemetry / no GPS config)
   * SBUS needs RX; on STM32F4 only UARTs with an `INVERTER_PIN_UARTn_RX` are ✓ (F7/H7/AT32 invert internally)
   * SmartAudio/Tramp needs a TX pin and also works on softserial
   * softserial that shares pins with a UART cannot be used together with that UART
6. **Review & Apply** – tabs with the diff of `target.c`, `target.h` and `config.c`, a summary of all
   warnings and the CLI commands. If the button is disabled, the reason is shown next to it (nothing
   selected, a blocking conflict, an open port-reference decision …). *Apply to* chooses between the
   original target and a **new target copy** (see *More tools*); *Export .patch…* saves the change set.
   When applying in place, backups `target.c.servo-backup` / `target.h.servo-backup` (and `config.c`) are
   written once; *Revert to Backup* restores them.
7. **Test Build** (optional) – runs `cmake .. && make <TARGET>` in `<inav>/build` (needs `cmake`).
   inav's cmake downloads the ARM compiler into `<inav>/downloads` and `<inav>/tools`; the app links both
   folders to one shared cache (`~/Library/Application Support/INAV Servo Support Assistant/toolchain`), so the
   compiler is downloaded only once, however often the inav folder is re-cloned. *File → Show ARM Toolchain
   Cache in Finder* opens it. After a successful build the log offers *Reveal .hex* and *Flash via DFU…*.
8. **After flashing** – paste the generated CLI commands (see below). Most important:
   `feature PWM_OUTPUT_ENABLE` – no inav target enables it by default and without it servo outputs are not started.

## Default port settings (config.c / target.h)

Many targets set default port functions in code – `SERIALRX_UART SERIAL_PORT_USART6` in `target.h`, or lines like
`serialConfigMutable()->portConfigs[findSerialPortIndexByIdentifier(SERIAL_PORT_USART6)].functionMask = FUNCTION_RX_SERIAL;`
in `config.c`. When a UART with such settings is converted, its card shows them and offers
**Move to UARTn** (suggested from *Remaining serial ports*), **Remove** or – in shared mode – **Keep**.
In dedicated mode a `config.c` reference must not stay: the removed port makes `findSerialPortIndexByIdentifier()`
return −1 and inav writes to `portConfigs[-1]`, so the receiver default is lost and memory is overwritten.
`config.c` is backed up and shown in the review screen like `target.c` / `target.h`.

## After flashing – CLI commands

The *After flashing* box (and the CLI tab in *Review & Apply*) generates paste-ready commands:
`feature PWM_OUTPUT_ENABLE`, `feature -LED_STRIP` when an LED timer is used, `serial <id> 0` for UARTs used as
servo pads in shared mode, `serial <id> <mask>` for the receiver / GPS / VTX ports from *Remaining serial ports*,
`set receiver_type` / `serialrx_provider`, and `save`.

## More tools

* **New target copy** – in *Review & Apply* choose *Apply to: New target copy* (default name `<TARGET>_SERVO`).
  A new folder `src/main/target/<NAME>` is created with the changes; the original target stays untouched, so
  `git pull` never conflicts. Variants are renamed (`MATEKF405OSD` → `MATEKF405OSD_SERVO`) and `target.h` maps
  them back to the original macros, so every `#ifdef` of the board keeps working. Build it with `make <NAME>`.
* **Export / apply .patch** – *Export .patch…* (review screen or *More* menu) saves the change set as a
  git-compatible patch; *File → Apply Patch…* runs `git apply --check` + `git apply` in the current inav folder,
  e.g. after updating to a new inav version.
* **Commit to git branch** – *File → Commit Target to Git Branch…* creates a branch (default `servo/<TARGET>`),
  switches to it and commits the target folder (backups excluded).
* **Flash** – after a successful *Test Build* the log offers *Reveal .hex* and *Flash via DFU…*: the hex is
  converted with the toolchain's `arm-none-eabi-objcopy` and written with `dfu-util` (`brew install dfu-util`),
  optionally with full chip erase. **No BOOT button needed:** if the board isn't in DFU mode yet, the app opens
  its USB serial port (`/dev/cu.usbmodem*`), enters the inav CLI (`#`) and sends `dfu`, then waits for the
  bootloader. *More → Reboot flight controller into DFU* does only this step. Close the inav configurator first
  (it holds the port); boards that don't run inav or don't respond still need the BOOT button.
* **Board pad names** – S1, M5, TX6, LED … are read from the comments in `target.c` / `target.h` and shown on
  the pin map, in the pad rows and on the motor chips.
* **DMA check** – on STM32F4/F7 the DMA streams of DShot motors (per channel, or per timer with
  `USE_DSHOT_DMAR`), the LED strip and the ADC are listed with any shared streams already present in the target.
  Servo outputs use no DMA; new servo entries get a DMA option that avoids used streams. H7/AT32 use a DMAMUX.

## What gets changed

`target.c` – new entries are appended at the end of `timerHardware[]` so existing output
numbering is unchanged:

```c
    // Servo outputs on UART / LED pads – added by INAV Servo Support Assistant
    DEF_TIM(TIM9, CH2, PA3,    TIM_USE_SERVO, 0, 0), // UART2 RX pad -> servo (INAV Servo Support Assistant)
```

If the pad already has a `DEF_TIM` line (e.g. `TIM_USE_PWM` or a softserial `TIM_USE_ANY`),
`TIM_USE_SERVO` is added to that line instead of creating a duplicate.

If the chosen timer also drives motor outputs, those motor `DEF_TIM` lines are commented out (tagged
with the app's name) so the timer is free for servos.

`target.h` – `MAX_PWM_OUTPUT_PORTS` is raised by the number of new outputs; in dedicated mode the UART
is disabled and `SERIAL_PORT_COUNT` is decreased; LED dedicated mode comments out the LED-strip defines and
removes `FEATURE_LED_STRIP` from `DEFAULT_FEATURES`. Default port settings (`SERIALRX_UART` …) are moved or
removed as chosen.

`config.c` – only if it references a converted UART: the reference is moved to another UART or removed.

After flashing: turn on "Enable motor and servo output" (CLI `feature PWM_OUTPUT_ENABLE`, then `save`) –
no inav target enables it by default and without it servo outputs are not started. Then add the servo
rules in the Mixer tab.

## How candidates are determined

| MCU | Pin → timer source |
|-----|--------------------|
| STM32F405 / F427 | embedded table from ST DS8626 / DS9405 (alternate function mapping) |
| STM32F411 | embedded table from ST DS10314 (TIM1-5, 9-11 only) |
| STM32F722 / F745 / F765 | inav `drivers/timer_def_stm32f7xx.h` AF table, cross-checked against the datasheet table |
| STM32H743 | inav `drivers/timer_def_stm32h7xx.h` AF table |
| AT32F435/437 | inav `drivers/timer_def_at32f43x.h` MUX table |

Every option is also validated against what inav can compile: the timer must exist in
`drivers/timer_<mcu>.c`, and `DEF_TIM_DMA__BTCH_<TIMx_CHy>` (plus the `DEF_TIM_AF__` entry on
F7/H7/AT32) must exist – otherwise `DEF_TIM()` would not build. Options the datasheet allows
but inav's tables lack are listed as rejected with the reason.

Conflict checks (blocking ✖ / warning ⚠):

* ⚠ timer drives motor outputs (motor-only or auto motor/servo) – motors and servos cannot share a timer in inav,
  so using that pad **disables those motor outputs** (their `DEF_TIM` lines are commented out). The *Motor outputs*
  strip shows motors 1, 2, 3, 4 … and which of them are still usable; options that keep all motors are preferred,
  and a selection that would disable every motor output is blocked
* ✖ the same timer channel is already used on another pin, or selected twice
* ✖ pin is an ADC channel
* ⚠ timer shared with the LED strip, beeper, PPM/PWM input or softserial
* ⚠ pin referenced by other defines (I2C, BIND_PIN, …), default receiver UART, UART1 in shared mode
* ℹ complementary (CHxN) channel

`Tools/servo_engine_reference.py` is a Python reference of the analysis engine
(`python3 Tools/servo_engine_reference.py ~/Desktop/inav [TARGET]`) used to validate the logic
against all targets.

## App icon

`AppIcon.png` (1024×1024) is picked up automatically by `build_app.sh` and converted to `AppIcon.icns`.
It is generated by `Tools/make_icon.py` (Python + Pillow): `python3 Tools/make_icon.py AppIcon.png`.

## Project layout

```
Package.swift
build_app.sh                      builds / zips the .app (--run, --arch, --universal)
Sources/INAVServoSupport/
  App/      INAVServoSupportApp.swift (window, menus), AppState.swift (state, apply, build, flash, git)
  Engine/   ChipDatabase      datasheet AF tables + inav timer/DMA tables
            TargetParser      target.c / target.h / config.c parser, pad names
            Analyzer          candidates, conflicts, motor-disable logic
            Patcher           edits target.c / target.h / config.c (+ line diff)
            PortPlanner       receiver / GPS / VTX assignment on the remaining ports
            PortReferences    default port settings in config.c / target.h
            DMACheck          DMA stream usage
            TargetCopy        new target copy + unified diff / .patch export
            ProcessRunner     shell commands (cmake, make, git, dfu-util)
  Metal/    GPIORenderer (MTKView + runtime-compiled shaders), GPIOMapView
  Views/    ContentView, SidebarView, SourceViews (start screen, source menu), TargetDetailView,
            PortPlanSection, ModeExplanationViews (how it works, motor strip, CLI box), Sheets (clone, log, review)
AppIcon.png
Tools/servo_engine_reference.py   Python reference of the analysis/patch engine
Tools/make_icon.py                renders AppIcon.png
RELEASE_NOTES.md
LICENSE                           GPL-3.0
```

## License

Copyright (C) 2026 lydianb79

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version – the same license as inav itself.
See [LICENSE](LICENSE) for the full text.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
