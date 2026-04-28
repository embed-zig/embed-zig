# lib/drivers

`lib/drivers` hosts chip-level drivers plus the narrow I/O contracts they
depend on.

This module is the replacement for the old `main`-branch HAL-era driver
layout. The goal is to keep useful register/control logic while avoiding a
global `hal` namespace. Drivers consume subsystem-local runtime contracts under
`lib/drivers/io` instead.

## Imports

```zig
const drivers = @import("drivers");

const io = drivers.io;
const Display = drivers.Display;
const Es7210 = drivers.audio.Es7210;
const Es8311 = drivers.audio.Es8311;
const Qmi8658 = drivers.imu.Qmi8658;
const Tca9554 = drivers.gpio.Tca9554;
const Fm175xx = drivers.nfc.Fm175xx;
```

The root module also re-exports the first-wave driver types directly:

- `drivers.Es7210`
- `drivers.Es8311`
- `drivers.Display`
- `drivers.Qmi8658`
- `drivers.Tca9554`
- `drivers.Fm175xx`

## Package Shape

```text
lib/
  drivers.zig
  drivers/
    README.md
    io.zig
    io/
      I2c.zig
      Delay.zig
      Spi.zig
    audio.zig
    audio/
      es7210.zig
      es7210.md
      es7210.pdf
      es8311.zig
      es8311.md
      es8311.pdf
    Display.zig
    display/
      Rgb.zig
    Imu.zig
    imu/
      qmi8658.zig
      qmi8658.md
      qmi8658.pdf
    gpio.zig
    gpio/
      tca9554.zig
      tca9554.md
      tca9554.pdf
    Nfc.zig
    nfc/
      AGENTS.md
      io.zig
      io/
        TypeA.zig
      fm175xx.zig
      fm175xx.md
      fm175xx/
        regs.zig
        type_a.zig
        ntag.zig
```

Category files such as `drivers/audio.zig` and `drivers/Imu.zig` are the
public entry points for each group. Individual driver files follow the
file-as-struct pattern so `@import("audio/es7210.zig")` yields the driver type
directly.

## I/O Contracts

`lib/drivers/io` owns the runtime contracts required by drivers.

Current phase-1 contracts:

- `drivers.io.I2c`: non-owning type-erased register/control bus
- `drivers.io.Delay`: non-owning type-erased duration sleep hook
- `drivers.io.Spi`: non-owning type-erased synchronous SPI bus

These wrappers are intentionally narrow. They should expose only the operations
that drivers actually need, and they should stay in `lib/drivers/io` rather
than being promoted into `lib/io`.

## Current Drivers

- `drivers.audio.Es7210`: ES7210 4-channel ADC control driver over I2C
- `drivers.audio.Es8311`: ES8311 mono codec control driver over I2C
- `drivers.Display`: type-erased display drawing driver surface
- `drivers.imu.Qmi8658`: QMI8658 IMU driver over I2C plus delay hook
- `drivers.gpio.Tca9554`: TCA9554 GPIO expander driver over I2C
- `drivers.nfc.Fm175xx`: FM175xx NFC reader driver over I2C or SPI, with
`ISO14443A` activation and raw `NTAG` reads

Drivers keep local reference material next to the implementation:

- a `.md` summary or notes file
- a `.pdf` datasheet tracked with Git LFS when that asset is checked into the
repo

## Usage

```zig
const drivers = @import("drivers");

var my_i2c = MyI2c{};
var my_delay = MyDelay{};

var imu = drivers.imu.Qmi8658.init(
    drivers.io.I2c.init(&my_i2c),
    drivers.io.Delay.init(&my_delay),
    .{ .address = 0x6A },
);

try imu.open();
const raw = try imu.readRaw();
_ = raw;

var my_spi = MySpi{};
var nfc = drivers.nfc.Fm175xx.initSpi(
    drivers.io.Spi.init(&my_spi),
    drivers.io.Delay.init(&my_delay),
    .{},
);

try nfc.open();
try nfc.setRf(.path1);
const card = try nfc.activateTypeA();
_ = card;
```

Ownership remains with the caller. `drivers.io.I2c`, `drivers.io.Spi`, and
`drivers.io.Delay` do not allocate and do not manage teardown of the wrapped
implementation.

## Design Rules

- Non-test library code in `lib/drivers` should not import `std` directly.
- Add new contracts to `lib/drivers/io` only when a real driver needs them.
- Prefer small explicit capability boundaries over broad HAL-style interfaces.
- Keep board policy, synchronization, pinmux, and power-tree setup outside
`lib/drivers` unless a chip driver explicitly requires a hook for it.

## Tests

The root `drivers/unit_tests` entry in `lib/drivers.zig` imports the in-file
unit tests for the current I/O wrappers and driver implementations.

For repo-level verification, use:

```sh
zig build test-drivers
```
