const embed = @import("embed_core");
const binding = @import("binding.zig");

const Pin = @This();

pub const Config = struct {
    pin: u32,
};

pin: u32,

pub fn init(config: Config) Pin {
    return .{
        .pin = config.pin,
    };
}

pub fn handle(self: *Pin) embed.drivers.Gpio {
    return embed.drivers.Gpio.init(self);
}

pub fn read(self: *Pin) embed.drivers.Gpio.Error!embed.drivers.Gpio.Level {
    var value: u32 = 0;
    try check(binding.bk_embed_gpio_read(self.pin, &value));
    return if (value == 0) .low else .high;
}

pub fn write(self: *Pin, level: embed.drivers.Gpio.Level) embed.drivers.Gpio.Error!void {
    try check(binding.bk_embed_gpio_write(self.pin, switch (level) {
        .low => 0,
        .high => 1,
    }));
}

pub fn setDirection(self: *Pin, direction: embed.drivers.Gpio.Direction) embed.drivers.Gpio.Error!void {
    try check(binding.bk_embed_gpio_set_direction(self.pin, switch (direction) {
        .output => 0,
        .input => 1,
    }));
}

pub fn configureInterrupt(self: *Pin, edge: embed.drivers.Gpio.Edge) embed.drivers.Gpio.Error!void {
    _ = edge;
    try check(binding.bk_embed_gpio_configure_interrupt(self.pin, 0));
}

fn check(rc: c_int) embed.drivers.Gpio.Error!void {
    return switch (rc) {
        binding.ok => {},
        binding.unsupported => error.Unsupported,
        binding.invalid_arg => error.InvalidArgument,
        else => error.PlatformError,
    };
}
