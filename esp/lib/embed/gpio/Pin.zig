const embed = @import("embed_core");
const binding = @import("binding.zig");

const Pin = @This();

pub const Config = struct {
    pin: c_int,
};

pin: c_int,
callback_ctx: ?*const anyopaque = null,
callback_fn: ?embed.drivers.Gpio.CallbackFn = null,

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
    try check(binding.esp_embed_gpio_read(self.pin, &value));
    return if (value == 0) .low else .high;
}

pub fn write(self: *Pin, level: embed.drivers.Gpio.Level) embed.drivers.Gpio.Error!void {
    try check(binding.esp_embed_gpio_write(self.pin, levelValue(level)));
}

pub fn setDirection(self: *Pin, direction: embed.drivers.Gpio.Direction) embed.drivers.Gpio.Error!void {
    try check(binding.esp_embed_gpio_set_direction(self.pin, switch (direction) {
        .output => 0,
        .input => 1,
    }));
}

pub fn configureInterrupt(self: *Pin, edge: embed.drivers.Gpio.Edge) embed.drivers.Gpio.Error!void {
    try check(binding.esp_embed_gpio_configure_interrupt(self.pin, edgeValue(edge)));
}

pub fn setEventCallback(self: *Pin, ctx: *const anyopaque, emit_fn: embed.drivers.Gpio.CallbackFn) void {
    self.callback_ctx = ctx;
    self.callback_fn = emit_fn;
    _ = binding.esp_embed_gpio_set_callback(self.pin, self, eventThunk);
}

pub fn clearEventCallback(self: *Pin) void {
    self.callback_ctx = null;
    self.callback_fn = null;
    _ = binding.esp_embed_gpio_clear_callback(self.pin);
}

fn eventThunk(ctx: ?*anyopaque, edge: u32, level: u32) callconv(.c) void {
    const raw_ctx = ctx orelse return;
    const self: *Pin = @ptrCast(@alignCast(raw_ctx));
    const callback_ctx = self.callback_ctx orelse return;
    const callback_fn = self.callback_fn orelse return;
    callback_fn(callback_ctx, .{
        .edge = edgeFromValue(edge),
        .level = levelFromValue(level),
    });
}

fn check(rc: c_int) embed.drivers.Gpio.Error!void {
    if (rc == binding.ok) return;
    return error.PlatformError;
}

fn levelValue(level: embed.drivers.Gpio.Level) u32 {
    return switch (level) {
        .low => 0,
        .high => 1,
    };
}

fn levelFromValue(value: u32) embed.drivers.Gpio.Level {
    return if (value == 0) .low else .high;
}

fn edgeValue(edge: embed.drivers.Gpio.Edge) u32 {
    return switch (edge) {
        .rising => binding.edge_rising,
        .falling => binding.edge_falling,
        .both => binding.edge_both,
        .low_level => binding.edge_low_level,
        .high_level => binding.edge_high_level,
    };
}

fn edgeFromValue(edge: u32) embed.drivers.Gpio.Edge {
    return switch (edge) {
        binding.edge_rising => .rising,
        binding.edge_falling => .falling,
        binding.edge_both => .both,
        binding.edge_low_level => .low_level,
        binding.edge_high_level => .high_level,
        else => .both,
    };
}
