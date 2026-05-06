# Chant

ESP32-S3 firmware example for the Lichuang SZP board. The app mounts a SPIFFS
partition containing Ogg Opus tracks, decodes them with the local `opus` package
and `embed.audio.ogg`, and plays PCM through the board ES8311 speaker path.

Hardware:

- Board: Lichuang SZP ESP32-S3
- Audio: ES8311 speaker path, I2S1 TX
- Display: ST7789 320x240
- Storage: 16MB flash board recommended

Build:

```sh
zig build -Didf=~/esp/idf-6...
```
