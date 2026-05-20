# ESP32-S3 DevKitC Board Notes

This directory contains the board integration for Espressif ESP32-S3-DevKitC-1
development boards.

## Source Links

- Official ESP32-S3-DevKitC-1 v1.1 user guide:
  <https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide_v1.1.html>
- Official ESP32-S3-DevKitC-1 v1.0 user guide:
  <https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide_v1.0.html>
- Official v1.1 schematic PDF:
  <https://dl.espressif.com/dl/schematics/SCH_ESP32-S3-DevKitC-1_V1.1_20221130.pdf>
- Official v1.0 schematic PDF:
  <https://dl.espressif.com/dl/SCH_ESP32-S3-DEVKITC-1_V1_20210312C.pdf>

Local schematic copies are stored under `docs/`:

- `docs/SCH_ESP32-S3-DevKitC-1_V1.1_20221130.pdf`
- `docs/SCH_ESP32-S3-DEVKITC-1_V1_20210312C.pdf`

## Hardware Summary

The official user guide describes ESP32-S3-DevKitC-1 as an entry-level board
using ESP32-S3-WROOM-1, ESP32-S3-WROOM-1U, or ESP32-S3-WROOM-2 modules. The
board exposes most available module GPIOs on pin headers and includes BOOT and
RESET buttons, USB-to-UART, native USB, a 3.3 V regulator, one addressable RGB
LED, and a 3.3 V power indicator LED.

## Current Board Components

| Component | Device / interface | Board wiring |
| --- | --- | --- |
| BOOT button | Momentary button | GPIO0, active low |
| RGB LED | SK68XXMINI-HS addressable RGB LED | v1.0 uses GPIO48; v1.1 uses GPIO38 |
| Power indicator | 3.3 V power LED | Fixed power indicator, not MCU GPIO-controlled |
| Wi-Fi / Bluetooth | ESP32-S3 radio | Provided by ESP32-S3 |

The current board code targets the v1.0 RGB LED wiring and drives the
addressable LED on GPIO48 through `ledStrip("strip")`.

## LED Notes

The official documentation lists only one MCU-controlled LED: the addressable
RGB LED. This is the same physical light exposed by the board code as
`ledStrip("strip")`; it can be set to red, green, blue, or other colors through
the LED strip driver.

The separate red power LED shown in the schematic is tied to the 3.3 V power
rail through a resistor. It is a power indicator and is not connected to an
ESP32-S3 GPIO, so it should not be exposed as `Switch` or `Pwm`.

The official v1.0 and v1.1 schematics do not show additional standalone red or
green user LEDs connected to ESP32-S3 GPIOs. If a third-party DevKitC-compatible
board adds such LEDs, it should be represented as a separate board variant with
its own schematic-backed GPIO mapping.
