# ESP Examples

This directory contains small, buildable ESP examples for the `glib` runtime
contracts. Most examples use the ESP runtime facade and IDF build helpers
directly; board demos may also use focused `embed` modules.

## Examples

Board columns are concrete development boards. Add another column when an example
supports another purchasable board with different pins, flash, PSRAM, or external
peripheral requirements.


| Example | ESP32-S3-DevKitC-1 | Lichuang SZP ESP32-S3 | Waveshare ESP32-S3 Touch AMOLED 1.8 | Waveshare ESP32-P4 WiFi6 Touch LCD 4.3 |
| --- | --- | --- | --- | --- |
| `blink` | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li><li>RGB LED: GPIO48</li></ul> | | | |
| `storage_smoke` | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li></ul> | | | |
| `wifi_led_threads` | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li><li>RGB LED: GPIO48</li><li>WiFi: 2.4GHz station</li></ul> | | | |
| `led_rainbow` | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li><li>RGB LED: GPIO48</li></ul> | | | |
| `launcher` with `-Dapp=zux_chant_touch` | | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li><li>PSRAM: 8MB</li><li>speaker: ES8311 + PA</li><li>display: ST7789 320x240</li><li>button: BOOT/GPIO0</li></ul> | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li><li>PSRAM: 8MB</li><li>display: SH8601 AMOLED</li><li>touch: touch controller</li><li>button: BOOT/GPIO0</li></ul> | <ul><li>chip: esp32p4 + WiFi coprocessor</li><li>flash: board default</li><li>display: LCD 800x480</li><li>touch: touch controller</li><li>button: BOOT/GPIO0</li></ul> |


## Build

Point each example at a local ESP-IDF checkout. Pass the serial port only when
flashing or monitoring a connected board.

```sh
cd blink
zig build -Didf=/path/to/esp-idf
```

```sh
cd storage_smoke
zig build -Didf=/path/to/esp-idf
```

```sh
cd wifi_led_threads
zig build -Didf=/path/to/esp-idf -Dwifi_ssid=my-ap -Dwifi_password=my-pass
```

```sh
cd led_rainbow
zig build -Didf=/path/to/esp-idf
```

```sh
cd launcher
zig build -Didf=/path/to/esp-idf -Dboard=szp -Dapp=zux_chant_touch
```

```sh
cd launcher
zig build flash -Didf=/path/to/esp-idf -Dboard=szp -Dapp=zux_chant_touch -Dport=<serial-port>
zig build monitor -Didf=/path/to/esp-idf -Dboard=szp -Dport=<serial-port>
```

Each example also exposes `flash` and `monitor` steps through the normal
`esp-zig` app flow. Board-specific serial ports, JTAG identifiers, and remote
service endpoints are local development inventory and should not be committed to
this README.
