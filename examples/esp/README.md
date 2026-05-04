# ESP Examples

This directory contains small, buildable ESP examples for the `glib` runtime
contracts. These examples use the ESP runtime facade and IDF build helpers
directly; they do not depend on the `embed` package.

## Examples

Board columns are concrete development boards. Add another column when an example
supports another purchasable board with different pins, flash, PSRAM, or external
peripheral requirements.


| Example | ESP32-S3-DevKitC-1 |
| --- | --- |
| `blink` | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li><li>RGB LED: GPIO48</li></ul> |
| `storage_smoke` | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li></ul> |
| `wifi_led_threads` | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li><li>RGB LED: GPIO48</li><li>WiFi: 2.4GHz station</li></ul> |
| `led_rainbow` | <ul><li>chip: esp32s3</li><li>flash: >= 16MB</li><li>RGB LED: GPIO48</li></ul> |


## Build

Point each example at a local ESP-IDF checkout:

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

Each example also exposes `flash` and `monitor` steps through the normal `esp-zig` app flow.