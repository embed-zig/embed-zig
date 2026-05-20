# SZP ESP32-S3 Board Notes

This directory contains the board integration for the LCKFB SZP ESP32-S3 board
(`立创·实战派ESP32-S3开发板`).

## Source Links

- Official hardware page:
  <https://wiki.lckfb.com/zh-hans/szpi-esp32s3/open-source-hardware/>
- Official board introduction:
  <https://openkits-wiki.easyeda.com/zh-hans/szpi-esp32s3/beginner/introduction.html>
- Lichuang open-source hardware project:
  <https://oshwhub.com/li-chuang-kai-fa-ban/li-chuang-shi-zhan-pai-esp32-s3-kai-fa-ban>
- Official download center:
  <https://wiki.lckfb.com/zh-hans/szpi-esp32s3/download-center.html>
- Baidu Netdisk package linked by the official download center:
  <https://pan.baidu.com/s/1Go4nKA6gJ14kPW9IwKRoPg?pwd=lckf> (`lckf`)

The official open-source hardware page links to the Oshwhub project for the
schematic, PCB, BOM, and 3D hardware views. At the time this note was written,
the public pages did not expose a direct schematic PDF to check into this
repository. If a PDF export is added later, place it in this directory; the
repository root `.gitattributes` already routes `*.pdf` through Git LFS.

## Hardware Summary

The official introduction describes the board as using an
`ESP32-S3-WROOM-1-N16R8` module with 16 MB Flash and 8 MB PSRAM. The board also
includes a GC0308 camera, a 2.0 inch IPS LCD, a capacitive touch panel, ES7210
and ES8311 audio chips, a QMI8658 6D motion sensor, TF card support, a USB hub,
one reset key, and one user/BOOT key.

## Current Board Components

| Component | Device / interface | Board wiring |
| --- | --- | --- |
| Power button | BOOT/user key | GPIO0, active low |
| I2C bus | Shared peripheral bus | SDA GPIO1, SCL GPIO2, 100 kHz in vendor examples |
| Display | ST7789-compatible SPI LCD, 320x240, RGB565 | SPI3, MOSI GPIO40, SCLK GPIO41, DC GPIO39, backlight GPIO42, CS via PCA9557 bit 0 |
| Touch | FT5x06-compatible capacitive touch | I2C address 0x38 on the shared I2C bus |
| IO expander | PCA9557 | I2C address 0x19; bit 0 LCD_CS, bit 1 PA_EN, bit 2 DVP_PWDN |
| IMU | QMI8658 | I2C address 0x6A on the shared I2C bus |
| Audio system | ES7210 ADC + ES8311 DAC/codec | I2S MCLK GPIO38, BCLK GPIO14, WS GPIO13, DOUT GPIO45, DIN GPIO12 |
| Camera | GC0308 | Power-down controlled through PCA9557 DVP_PWDN |
| Storage | TF card | 1-bit SD mode in the official examples |
| Wi-Fi / Bluetooth | ESP32-S3 radio | Provided by ESP32-S3 |

The current `Board` exports only the components wired by the examples in this
repository. Storage and camera are documented here as board hardware but are not
yet exposed by the board component.
