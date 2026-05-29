//! ST7701 RGB/MIPI TFT LCD controller driver.
//!
//! The controller driver owns ST7701 command/register names and panel init
//! presets. Board code owns the physical bus, reset pin, DSI/DPI timing,
//! framebuffer/DMA policy, and backlight.

const glib = @import("glib");

const DisplaySurface = @import("../Display.zig");
const Delay = @import("../Delay.zig");
const Dbi = @import("Dbi.zig");
const Flush = @import("Flush.zig");
const Rgb = @import("Rgb.zig");

const st7701 = @This();

const Register = enum(u8) {
    software_reset = 0x01,
    sleep_in = 0x10,
    sleep_out = 0x11,
    display_off = 0x28,
    display_on = 0x29,
    column_address_set = 0x2A,
    row_address_set = 0x2B,
    memory_write = 0x2C,
    memory_access_control = 0x36,
    pixel_format_set = 0x3A,
    vendor_b0 = 0xB0,
    vendor_b1 = 0xB1,
    vendor_b2 = 0xB2,
    vendor_b3 = 0xB3,
    vendor_b5 = 0xB5,
    vendor_b7 = 0xB7,
    vendor_b8 = 0xB8,
    vendor_b9 = 0xB9,
    vendor_bb = 0xBB,
    vendor_bc = 0xBC,
    vendor_c0 = 0xC0,
    vendor_c1 = 0xC1,
    vendor_c2 = 0xC2,
    vendor_cc = 0xCC,
    vendor_d0 = 0xD0,
    vendor_e0 = 0xE0,
    vendor_e1 = 0xE1,
    vendor_e2 = 0xE2,
    vendor_e3 = 0xE3,
    vendor_e4 = 0xE4,
    vendor_e5 = 0xE5,
    vendor_e6 = 0xE6,
    vendor_e7 = 0xE7,
    vendor_e8 = 0xE8,
    vendor_eb = 0xEB,
    vendor_ec = 0xEC,
    vendor_ed = 0xED,
    vendor_ef = 0xEF,
    command_bank_select = 0xFF,
};

pub const PixelFormat = enum(u8) {
    rgb565 = 0x55,
    rgb666 = 0x66,
    rgb888 = 0x77,
};

pub const Config = struct {
    width: u16 = 480,
    height: u16 = 800,
    pixel_format: PixelFormat = .rgb565,
    sleep_out_delay_ms: u16 = 120,
};

dbi: Dbi,
delay: Delay,
config: Config,
is_open: bool = false,

pub fn init(dbi: Dbi, delay: Delay, config: Config) st7701 {
    return .{
        .dbi = dbi,
        .delay = delay,
        .config = config,
    };
}

pub fn defaultWaveshareP443Config() Config {
    return .{};
}

pub fn open(self: *st7701) Dbi.Error!void {
    try self.openWaveshareP443();
    self.is_open = true;
}

pub fn setPixelFormat(self: *st7701, format: PixelFormat) Dbi.Error!void {
    try self.send(.pixel_format_set, &.{@intFromEnum(format)});
}

pub fn sleepOut(self: *st7701) Dbi.Error!void {
    try self.send(.sleep_out, &.{});
    self.delay.sleep(@as(glib.time.duration.Duration, self.config.sleep_out_delay_ms) * glib.time.duration.MilliSecond);
}

pub fn displayOn(self: *st7701) Dbi.Error!void {
    try self.send(.display_on, &.{});
}

pub fn displayOff(self: *st7701) Dbi.Error!void {
    try self.send(.display_off, &.{});
}

pub fn setAddressWindow(self: *st7701, x0: u16, y0: u16, x1: u16, y1: u16) Dbi.Error!void {
    var column: [4]u8 = undefined;
    var row: [4]u8 = undefined;
    encodeRange(&column, x0, x1);
    encodeRange(&row, y0, y1);
    try self.send(.column_address_set, &column);
    try self.send(.row_address_set, &row);
}

pub fn writeMemoryData(self: *st7701, data: []const u8) Dbi.Error!void {
    try self.dbi.writeCommandData(@intFromEnum(Register.memory_write), data);
}

fn send(self: *st7701, register: Register, data: []const u8) Dbi.Error!void {
    try self.dbi.writeCommand(@intFromEnum(register), data);
}

fn openWaveshareP443(self: *st7701) Dbi.Error!void {
    try self.send(.command_bank_select, &cmd_bank_13);
    try self.send(.vendor_ef, &.{0x08});
    try self.send(.command_bank_select, &cmd_bank_10);
    try self.send(.vendor_c0, &porch_control);
    try self.send(.vendor_c1, &gate_control);
    try self.send(.vendor_c2, &inversion_control);
    try self.send(.vendor_cc, &panel_control);
    try self.send(.vendor_b0, &positive_gamma);
    try self.send(.vendor_b1, &negative_gamma);
    try self.send(.command_bank_select, &cmd_bank_11);
    try self.send(.vendor_b0, &power_b0);
    try self.send(.vendor_b1, &power_b1);
    try self.send(.vendor_b2, &power_b2);
    try self.send(.vendor_b3, &power_b3);
    try self.send(.vendor_b5, &power_b5);
    try self.send(.vendor_b7, &power_b7);
    try self.send(.vendor_b8, &power_b8);
    try self.send(.vendor_b9, &power_b9);
    try self.send(.vendor_bb, &power_bb);
    try self.send(.vendor_bc, &power_bc);
    try self.send(.vendor_c1, &power_c1);
    try self.send(.vendor_c2, &power_c2);
    try self.send(.vendor_d0, &power_d0);
    try self.send(.vendor_e0, &vendor_e0);
    try self.send(.vendor_e1, &vendor_e1);
    try self.send(.vendor_e2, &vendor_e2);
    try self.send(.vendor_e3, &vendor_e3);
    try self.send(.vendor_e4, &vendor_e4);
    try self.send(.vendor_e5, &vendor_e5);
    try self.send(.vendor_e6, &vendor_e6);
    try self.send(.vendor_e7, &vendor_e7);
    try self.send(.vendor_e8, &vendor_e8);
    try self.send(.vendor_eb, &vendor_eb);
    try self.send(.vendor_ec, &vendor_ec);
    try self.send(.vendor_ed, &vendor_ed);
    try self.send(.vendor_ef, &vendor_ef);
    try self.send(.command_bank_select, &cmd_bank_00);
    try self.sleepOut();
    try self.displayOn();
}

fn encodeRange(out: *[4]u8, start: u16, end: u16) void {
    out.* = .{
        @intCast(start >> 8),
        @intCast(start & 0x00FF),
        @intCast(end >> 8),
        @intCast(end & 0x00FF),
    };
}

pub const Display = struct {
    const Error = DisplaySurface.Error;

    pub const OpenFn = *const fn (controller: *st7701) Error!void;
    pub const BrightnessFn = *const fn (level: u8) Error!void;
    pub const FlushRgb565Fn = *const fn (x: u16, y: u16, w: u16, h: u16, pixels: []const u16) Error!void;

    pub const Config = struct {
        allocator: glib.std.mem.Allocator,
        dbi: Dbi,
        delay: Delay,
        controller: st7701.Config,
        flush: Flush.Config,
        open: ?OpenFn = null,
        set_brightness: ?BrightnessFn = null,
        flush_rgb565: ?FlushRgb565Fn = null,
        initial_brightness: u8 = 255,
    };

    allocator: glib.std.mem.Allocator,
    controller: st7701,
    flush_config: Flush.Config,
    rgb565_buffer: []u16,
    set_brightness: ?BrightnessFn,
    flush_rgb565: ?FlushRgb565Fn,
    brightness_level: u8,
    is_enabled: bool = true,

    fn init(config: Display.Config) !*Display {
        const buffer = try config.allocator.alloc(u16, Flush.maxChunkPixels(config.flush));
        var buffer_owned = true;
        errdefer if (buffer_owned) config.allocator.free(buffer);

        const self = try config.allocator.create(Display);
        var self_initialized = false;
        errdefer if (!self_initialized) config.allocator.destroy(self);

        self.* = .{
            .allocator = config.allocator,
            .controller = st7701.init(config.dbi, config.delay, config.controller),
            .flush_config = config.flush,
            .rgb565_buffer = buffer,
            .set_brightness = config.set_brightness,
            .flush_rgb565 = config.flush_rgb565,
            .brightness_level = config.initial_brightness,
        };
        buffer_owned = false;
        self_initialized = true;
        errdefer self.deinit();

        if (config.open) |open_fn| {
            try open_fn(&self.controller);
        } else {
            self.controller.open() catch return error.DisplayError;
        }

        return self;
    }

    fn deinit(self: *Display) void {
        self.allocator.free(self.rgb565_buffer);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn width(self: *Display) u16 {
        return Flush.width(self.flush_config);
    }

    fn height(self: *Display) u16 {
        return Flush.height(self.flush_config);
    }

    fn setEnabled(self: *Display, is_enabled: bool) Error!void {
        if (self.is_enabled == is_enabled) return;
        if (is_enabled) {
            self.controller.displayOn() catch return error.DisplayError;
        } else {
            self.controller.displayOff() catch return error.DisplayError;
        }
        if (self.set_brightness) |set_brightness_fn| {
            try set_brightness_fn(if (is_enabled) self.brightness_level else 0);
        }
        self.is_enabled = is_enabled;
    }

    fn enabled(self: *Display) Error!bool {
        return self.is_enabled;
    }

    fn setBrightness(self: *Display, level: u8) Error!void {
        if (self.set_brightness) |set_brightness_fn| {
            try set_brightness_fn(if (self.is_enabled) level else 0);
        }
        self.brightness_level = level;
    }

    fn brightness(self: *Display) Error!u8 {
        return self.brightness_level;
    }

    fn maxFlushPixels(self: *Display) Error!usize {
        return self.rgb565_buffer.len;
    }

    fn flush(
        self: *Display,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        pixels: []const Rgb,
    ) Error!void {
        if (w == 0 or h == 0) return;
        try Flush.validate(self.flush_config, x, y, w, h, pixels);

        const chunk = Flush.encodeChunk(self.flush_config, self.rgb565_buffer, pixels, 0, w, h) catch return error.OutOfBounds;
        const area = Flush.nativeArea(self.flush_config, x, y, w, 0, h);
        if (self.flush_rgb565) |flush_rgb565| {
            try flush_rgb565(area.x, area.y, area.w, area.h, chunk);
            return;
        }
        self.controller.setAddressWindow(area.x, area.y, area.x + area.w - 1, area.y + area.h - 1) catch return error.DisplayError;
        self.controller.writeMemoryData(glib.std.mem.sliceAsBytes(chunk)) catch return error.DisplayError;
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Display = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn widthFn(ptr: *anyopaque) u16 {
        const self: *Display = @ptrCast(@alignCast(ptr));
        return self.width();
    }

    fn heightFn(ptr: *anyopaque) u16 {
        const self: *Display = @ptrCast(@alignCast(ptr));
        return self.height();
    }

    fn setEnabledFn(ptr: *anyopaque, is_enabled: bool) Error!void {
        const self: *Display = @ptrCast(@alignCast(ptr));
        return self.setEnabled(is_enabled);
    }

    fn enabledFn(ptr: *anyopaque) Error!bool {
        const self: *Display = @ptrCast(@alignCast(ptr));
        return self.enabled();
    }

    fn setBrightnessFn(ptr: *anyopaque, level: u8) Error!void {
        const self: *Display = @ptrCast(@alignCast(ptr));
        return self.setBrightness(level);
    }

    fn brightnessFn(ptr: *anyopaque) Error!u8 {
        const self: *Display = @ptrCast(@alignCast(ptr));
        return self.brightness();
    }

    fn maxFlushPixelsFn(ptr: *anyopaque) Error!usize {
        const self: *Display = @ptrCast(@alignCast(ptr));
        return self.maxFlushPixels();
    }

    fn flushFn(
        ptr: *anyopaque,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        pixels: []const Rgb,
    ) Error!void {
        const self: *Display = @ptrCast(@alignCast(ptr));
        return self.flush(x, y, w, h, pixels);
    }

    const vtable = DisplaySurface.VTable{
        .deinit = deinitFn,
        .width = widthFn,
        .height = heightFn,
        .setEnabled = setEnabledFn,
        .enabled = enabledFn,
        .setBrightness = setBrightnessFn,
        .brightness = brightnessFn,
        .maxFlushPixels = maxFlushPixelsFn,
        .flush = flushFn,
    };
};

pub fn display(config: Display.Config) !DisplaySurface {
    const display_impl = try Display.init(config);
    return .{
        .ptr = display_impl,
        .vtable = &Display.vtable,
    };
}

const cmd_bank_13 = [_]u8{ 0x77, 0x01, 0x00, 0x00, 0x13 };
const cmd_bank_10 = [_]u8{ 0x77, 0x01, 0x00, 0x00, 0x10 };
const cmd_bank_11 = [_]u8{ 0x77, 0x01, 0x00, 0x00, 0x11 };
const cmd_bank_00 = [_]u8{ 0x77, 0x01, 0x00, 0x00, 0x00 };

const porch_control = [_]u8{ 0x63, 0x00 };
const gate_control = [_]u8{ 0x0D, 0x02 };
const inversion_control = [_]u8{ 0x17, 0x08 };
const panel_control = [_]u8{0x10};
const positive_gamma = [_]u8{ 0x40, 0xC9, 0x94, 0x0E, 0x10, 0x05, 0x0B, 0x09, 0x08, 0x26, 0x04, 0x52, 0x10, 0x69, 0x6B, 0x69 };
const negative_gamma = [_]u8{ 0x40, 0xD2, 0x98, 0x0C, 0x92, 0x07, 0x09, 0x08, 0x07, 0x25, 0x02, 0x0E, 0x0C, 0x6E, 0x78, 0x55 };

const power_b0 = [_]u8{0x5D};
const power_b1 = [_]u8{0x4E};
const power_b2 = [_]u8{0x87};
const power_b3 = [_]u8{0x80};
const power_b5 = [_]u8{0x4E};
const power_b7 = [_]u8{0x85};
const power_b8 = [_]u8{0x21};
const power_b9 = [_]u8{ 0x10, 0x1F };
const power_bb = [_]u8{0x03};
const power_bc = [_]u8{0x00};
const power_c1 = [_]u8{0x78};
const power_c2 = [_]u8{0x78};
const power_d0 = [_]u8{0x88};

const vendor_e0 = [_]u8{ 0x00, 0x3A, 0x02 };
const vendor_e1 = [_]u8{ 0x04, 0xA0, 0x00, 0xA0, 0x05, 0xA0, 0x00, 0xA0, 0x00, 0x40, 0x40 };
const vendor_e2 = [_]u8{ 0x30, 0x00, 0x40, 0x40, 0x32, 0xA0, 0x00, 0xA0, 0x00, 0xA0, 0x00, 0xA0, 0x00 };
const vendor_e3 = [_]u8{ 0x00, 0x00, 0x33, 0x33 };
const vendor_e4 = [_]u8{ 0x44, 0x44 };
const vendor_e5 = [_]u8{ 0x09, 0x2E, 0xA0, 0xA0, 0x0B, 0x30, 0xA0, 0xA0, 0x05, 0x2A, 0xA0, 0xA0, 0x07, 0x2C, 0xA0, 0xA0 };
const vendor_e6 = [_]u8{ 0x00, 0x00, 0x33, 0x33 };
const vendor_e7 = [_]u8{ 0x44, 0x44 };
const vendor_e8 = [_]u8{ 0x08, 0x2D, 0xA0, 0xA0, 0x0A, 0x2F, 0xA0, 0xA0, 0x04, 0x29, 0xA0, 0xA0, 0x06, 0x2B, 0xA0, 0xA0 };
const vendor_eb = [_]u8{ 0x00, 0x00, 0x4E, 0x4E, 0x00, 0x00, 0x00 };
const vendor_ec = [_]u8{ 0x08, 0x01 };
const vendor_ed = [_]u8{ 0xB0, 0x2B, 0x98, 0xA4, 0x56, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xF7, 0x65, 0x4A, 0x89, 0xB2, 0x0B };
const vendor_ef = [_]u8{ 0x08, 0x08, 0x08, 0x45, 0x3F, 0x54 };

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn exposesWaveshareP4PanelPreset() !void {
            const config = defaultWaveshareP443Config();
            try grt.std.testing.expectEqual(@as(u16, 480), config.width);
            try grt.std.testing.expectEqual(@as(u16, 800), config.height);
            try grt.std.testing.expectEqual(PixelFormat.rgb565, config.pixel_format);
            try grt.std.testing.expectEqual(@as(u16, 120), config.sleep_out_delay_ms);
        }

        fn openEmitsWaveshareP4PanelPreset() !void {
            const FakeBus = struct {
                commands: [39]u8 = [_]u8{0} ** 39,
                data_lens: [39]usize = [_]usize{0} ** 39,
                count: usize = 0,

                pub fn writeCommand(self: *@This(), command: u8, data: []const u8) Dbi.Error!void {
                    self.commands[self.count] = command;
                    self.data_lens[self.count] = data.len;
                    self.count += 1;
                }

                pub fn writeData(_: *@This(), _: []const u8) Dbi.Error!void {}

                pub fn writeCommandData(_: *@This(), _: u8, _: []const u8) Dbi.Error!void {}
            };
            const FakeDelay = struct {
                sleep_count: usize = 0,
                last_duration: glib.time.duration.Duration = 0,

                pub fn sleep(self: *@This(), duration: glib.time.duration.Duration) void {
                    self.sleep_count += 1;
                    self.last_duration = duration;
                }
            };

            var fake_bus = FakeBus{};
            var fake_delay = FakeDelay{};
            var driver = st7701.init(Dbi.init(&fake_bus), Delay.init(&fake_delay), .{});

            try driver.open();

            try grt.std.testing.expectEqual(@as(usize, 39), fake_bus.count);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.command_bank_select)), fake_bus.commands[0]);
            try grt.std.testing.expectEqual(@as(usize, 5), fake_bus.data_lens[0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.sleep_out)), fake_bus.commands[37]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.display_on)), fake_bus.commands[38]);
            try grt.std.testing.expectEqual(@as(usize, 1), fake_delay.sleep_count);
            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 120 * glib.time.duration.MilliSecond), fake_delay.last_duration);
            try grt.std.testing.expect(driver.is_open);
        }

        fn setAddressWindowEmitsColumnAndRowCommands() !void {
            const FakeBus = struct {
                commands: [2]u8 = .{ 0, 0 },
                data: [2][4]u8 = [_][4]u8{.{ 0, 0, 0, 0 }} ** 2,
                count: usize = 0,

                pub fn writeCommand(self: *@This(), command: u8, data: []const u8) Dbi.Error!void {
                    self.commands[self.count] = command;
                    @memcpy(self.data[self.count][0..data.len], data);
                    self.count += 1;
                }

                pub fn writeData(_: *@This(), _: []const u8) Dbi.Error!void {}

                pub fn writeCommandData(_: *@This(), _: u8, _: []const u8) Dbi.Error!void {}
            };
            const FakeDelay = struct {
                pub fn sleep(_: *@This(), _: glib.time.duration.Duration) void {}
            };

            var fake_bus = FakeBus{};
            var fake_delay = FakeDelay{};
            var driver = st7701.init(Dbi.init(&fake_bus), Delay.init(&fake_delay), .{});

            try driver.setAddressWindow(1, 2, 319, 239);

            try grt.std.testing.expectEqual(@as(usize, 2), fake_bus.count);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.column_address_set)), fake_bus.commands[0]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x01, 0x3F }, &fake_bus.data[0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.row_address_set)), fake_bus.commands[1]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x00, 0x02, 0x00, 0xEF }, &fake_bus.data[1]);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.exposesWaveshareP4PanelPreset() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.openEmitsWaveshareP4PanelPreset() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.setAddressWindowEmitsColumnAndRowCommands() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
