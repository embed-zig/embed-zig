# FM175xx Notes

`lib/drivers/nfc/fm175xx.zig` is the first-wave Zig port of the external
FM175xx reader path used by current product code.

## Scope

- Transport support: `I2C` and `SPI`
- ISO scope: `ISO14443A`
- Tag scope: raw `NTAG` read helpers

## Non-goals

- Type B in phase 1
- product polling loops or removal heuristics
- NDEF parsing inside the chip driver

## Source Material

- FM175xx migration notes in `lib/drivers/nfc/AGENTS.md`
- the colocated Zig driver and helpers in `lib/drivers/nfc/fm175xx.zig` and
  `lib/drivers/nfc/fm175xx/`
- the external FM175xx C implementation and transport backends used during the
  port, summarized in the AGENTS document rather than hard-coded here as
  machine-local paths

## Layout

- `fm175xx.zig`: public file-as-struct entry point
- `fm175xx/regs.zig`: register and command constants
- `fm175xx/type_a.zig`: reusable Type A activation logic over `nfc.io.TypeA`
- `fm175xx/ntag.zig`: raw NTAG read helpers over `nfc.io.TypeA`
