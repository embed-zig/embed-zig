# Waveshare ESP32-S3 Touch AMOLED 1.8 Board Notes

This directory contains the board integration for the Waveshare
ESP32-S3-Touch-AMOLED-1.8 device.

## Source Links

- Product documentation:
  <https://docs.waveshare.net/ESP32-S3-Touch-AMOLED-1.8/Resources-And-Documents/>
- Official ESP-IDF reference examples distributed from the product page were
  used to verify the pin map and peripheral setup.

## Hardware Summary

The board is an ESP32-S3 device with a 1.8 inch 368x448 AMOLED panel, capacitive
touch, ES8311 audio codec, TCA9554 IO expander, SD card, RTC, IMU, Wi-Fi, and
Bluetooth.

## Current Board Components

| Component | Device / interface | Board wiring |
| --- | --- | --- |
| BOOT button | Momentary button | GPIO0, active low |
| I2C bus | Shared peripheral bus | SDA GPIO15, SCL GPIO14, 200 kHz in vendor examples |
| IO expander | TCA9554 | I2C address 0x20; pins 0, 1, and 2 power/reset board peripherals |
| Display | SH8601 AMOLED, 368x448, RGB565 | QSPI SPI2, CS GPIO12, PCLK GPIO11, DATA0 GPIO4, DATA1 GPIO5, DATA2 GPIO6, DATA3 GPIO7 |
| Touch | FT5x06-compatible capacitive touch | I2C address 0x38, INT GPIO21 |
| Audio system | ES8311 codec | I2S MCLK GPIO16, BCLK GPIO9, WS GPIO45, DOUT GPIO8, DIN GPIO10, PA GPIO46 |
| Wi-Fi / Bluetooth | ESP32-S3 radio | Provided by ESP32-S3 |

The current board exports BOOT button, display, touch, audio system, and Wi-Fi.
The ES8311 codec provides a single microphone channel; the audio system uses the
software speaker mix as the microphone reference signal.
