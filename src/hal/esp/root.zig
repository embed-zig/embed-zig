const adc = @import("adc.zig");
const display = @import("display.zig");
const gpio = @import("gpio.zig");
const hci = @import("hci.zig");
const i2c = @import("i2c.zig");
const i2s = @import("i2s.zig");
const kvs = @import("kvs.zig");
const led = @import("led.zig");
const led_strip = @import("led_strip.zig");
const mic_es7210 = @import("mic/es7210.zig");
const pwm = @import("pwm.zig");
const rtc = @import("rtc.zig");
const spi = @import("spi.zig");
const speaker_es8311 = @import("speaker/es8311.zig");
const temp_sensor = @import("temp_sensor.zig");
const uart = @import("uart.zig");
const wifi = @import("wifi.zig");
const hal = @import("hal");

pub const Gpio = hal.gpio.from(.{
    .Driver = gpio.Driver,
    .meta = .{ .id = "esp.gpio" },
});

pub const Hci = hal.hci.from(.{
    .Driver = hci.Driver,
    .meta = .{ .id = "esp.hci" },
});

pub const Adc = hal.adc.from(.{
    .Driver = adc.Driver,
    .meta = .{ .id = "esp.adc" },
});

pub const Led = hal.led.from(.{
    .Driver = led.Driver,
    .meta = .{ .id = "esp.led" },
});

pub const LedStrip = hal.led_strip.from(.{
    .Driver = led_strip.Driver,
    .meta = .{ .id = "esp.led_strip" },
});

pub const I2c = hal.i2c.from(.{
    .Driver = i2c.Driver,
    .meta = .{ .id = "esp.i2c" },
});

pub const Spi = hal.spi.from(.{
    .Driver = spi.Driver,
    .meta = .{ .id = "esp.spi" },
});

pub const I2s = hal.i2s.from(.{
    .Driver = i2s.Driver,
    .EndpointHandle = i2s.EndpointHandle,
    .meta = .{ .id = "esp.i2s" },
});

pub const Pwm = hal.pwm.from(.{
    .Driver = pwm.Driver,
    .meta = .{ .id = "esp.pwm" },
});

pub const Uart = hal.uart.from(.{
    .Driver = uart.Driver,
    .meta = .{ .id = "esp.uart" },
});

pub const Wifi = hal.wifi.from(.{
    .Driver = wifi.Driver,
    .meta = .{ .id = "esp.wifi" },
});

pub const Kvs = hal.kvs.from(.{
    .Driver = kvs.Driver,
    .meta = .{ .id = "esp.kvs" },
});

pub const Display = hal.display.from(.{
    .Driver = display.Driver,
    .meta = .{ .id = "esp.display" },
});

pub const MicEs7210 = hal.mic.from(.{
    .Driver = mic_es7210.Driver,
    .meta = .{ .id = "esp.mic.es7210" },
});

pub const SpeakerEs8311 = hal.speaker.from(.{
    .Driver = speaker_es8311.Driver,
    .meta = .{ .id = "esp.speaker.es8311" },
});

pub const RtcReader = hal.rtc.reader.from(.{
    .Driver = rtc.Driver,
    .meta = .{ .id = "esp.rtc" },
});

pub const RtcWriter = hal.rtc.writer.from(.{
    .Driver = rtc.Driver,
    .meta = .{ .id = "esp.rtc" },
});

pub const TempSensor = hal.temp_sensor.from(.{
    .Driver = temp_sensor.Driver,
    .meta = .{ .id = "esp.temp_sensor" },
});
