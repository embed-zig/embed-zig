//! SH8601 QSPI AMOLED controller driver.
//!
//! This file owns SH8601 command names and panel init presets. The platform
//! layer owns QSPI bus creation, DMA transfer limits, and display memory writes.

const glib = @import("glib");

const DisplaySurface = @import("../Display.zig");
const Delay = @import("../Delay.zig");
const Dbi = @import("Dbi.zig");
const Flush = @import("Flush.zig");
const Rgb = @import("Rgb.zig");

const sh8601 = @This();

const Register = enum(u8) {
    software_reset = 0x01,
    sleep_out = 0x11,
    display_off = 0x28,
    display_on = 0x29,
    column_address_set = 0x2A,
    row_address_set = 0x2B,
    memory_write = 0x2C,
    memory_access_control = 0x36,
    pixel_format_set = 0x3A,
    tear_effect_line_on = 0x35,
    tear_scanline = 0x44,
    write_display_brightness = 0x51,
    write_ctrl_display = 0x53,
};

pub const Qspi = struct {
    pub const write_command_opcode: u8 = 0x02;
    pub const write_color_opcode: u8 = 0x32;
};

pub const PixelFormat = enum(u8) {
    rgb565 = 0x55,
    rgb666 = 0x66,
};

pub const MemoryAccessControl = struct {
    value: u8 = 0x00,

    pub fn encode(self: MemoryAccessControl) u8 {
        return self.value;
    }
};

pub const TearEffectLineMode = enum(u8) {
    vblanking = 0x00,
    vblanking_and_hblanking = 0x01,
};

pub const ControlDisplay = struct {
    brightness_control: bool = true,
    display_dimming: bool = false,
    backlight_control: bool = false,

    pub fn encode(self: ControlDisplay) u8 {
        var value: u8 = 0;
        if (self.brightness_control) value |= 0x20;
        if (self.display_dimming) value |= 0x08;
        if (self.backlight_control) value |= 0x04;
        return value;
    }
};

pub const Config = struct {
    native_width: u16 = 368,
    native_height: u16 = 448,
    logical_width: u16 = 448,
    logical_height: u16 = 368,
    memory_access_control: MemoryAccessControl = .{},
    pixel_format: PixelFormat = .rgb565,
    tear_scanline: u16 = 0x01D1,
    tear_effect_line_mode: TearEffectLineMode = .vblanking,
    control_display: ControlDisplay = .{},
    initial_brightness: u8 = 255,
    reset_delay_ms: u16 = 80,
    sleep_out_delay_ms: u16 = 120,
    control_display_delay_ms: u16 = 10,
    brightness_off_delay_ms: u16 = 10,
    display_on_delay_ms: u16 = 10,
};

dbi: Dbi,
delay: Delay,
config: Config,
is_open: bool = false,

pub fn init(dbi: Dbi, delay: Delay, config: Config) sh8601 {
    return .{
        .dbi = dbi,
        .delay = delay,
        .config = config,
    };
}

pub fn defaultWvAmoled18Config() Config {
    return .{};
}

pub fn open(self: *sh8601) Dbi.Error!void {
    try self.setMemoryAccessControl(self.config.memory_access_control);
    try self.setPixelFormat(self.config.pixel_format);
    try self.sleepOut();
    try self.setTearScanline(self.config.tear_scanline);
    try self.setTearEffectLine(self.config.tear_effect_line_mode);
    try self.setControlDisplay(self.config.control_display);
    self.delay.sleep(@as(glib.time.duration.Duration, self.config.control_display_delay_ms) * glib.time.duration.MilliSecond);
    try self.setAddressWindow(0, 0, self.config.native_width - 1, self.config.native_height - 1);
    try self.setBrightness(0);
    self.delay.sleep(@as(glib.time.duration.Duration, self.config.brightness_off_delay_ms) * glib.time.duration.MilliSecond);
    try self.displayOn();
    self.delay.sleep(@as(glib.time.duration.Duration, self.config.display_on_delay_ms) * glib.time.duration.MilliSecond);
    try self.setBrightness(self.config.initial_brightness);
    self.is_open = true;
}

pub fn softwareReset(self: *sh8601) Dbi.Error!void {
    try self.send(.software_reset, &.{});
    self.delay.sleep(@as(glib.time.duration.Duration, self.config.reset_delay_ms) * glib.time.duration.MilliSecond);
}

pub fn sleepOut(self: *sh8601) Dbi.Error!void {
    try self.send(.sleep_out, &.{});
    self.delay.sleep(@as(glib.time.duration.Duration, self.config.sleep_out_delay_ms) * glib.time.duration.MilliSecond);
}

pub fn displayOn(self: *sh8601) Dbi.Error!void {
    try self.send(.display_on, &.{});
}

pub fn displayOff(self: *sh8601) Dbi.Error!void {
    try self.send(.display_off, &.{});
}

pub fn setBrightness(self: *sh8601, brightness: u8) Dbi.Error!void {
    try self.send(.write_display_brightness, &.{brightness});
}

pub fn setPixelFormat(self: *sh8601, format: PixelFormat) Dbi.Error!void {
    try self.send(.pixel_format_set, &.{@intFromEnum(format)});
}

pub fn setTearScanline(self: *sh8601, line: u16) Dbi.Error!void {
    var data: [2]u8 = undefined;
    encodeU16(&data, line);
    try self.send(.tear_scanline, &data);
}

pub fn setTearEffectLine(self: *sh8601, mode: TearEffectLineMode) Dbi.Error!void {
    try self.send(.tear_effect_line_on, &.{@intFromEnum(mode)});
}

pub fn setControlDisplay(self: *sh8601, control: ControlDisplay) Dbi.Error!void {
    try self.send(.write_ctrl_display, &.{control.encode()});
}

pub fn setAddressWindow(self: *sh8601, x0: u16, y0: u16, x1: u16, y1: u16) Dbi.Error!void {
    var column: [4]u8 = undefined;
    var row: [4]u8 = undefined;
    encodeRange(&column, x0, x1);
    encodeRange(&row, y0, y1);
    try self.send(.column_address_set, &column);
    try self.send(.row_address_set, &row);
}

pub fn writeMemoryData(self: *sh8601, data: []const u8) Dbi.Error!void {
    try self.dbi.writeCommandData(@intFromEnum(Register.memory_write), data);
}

fn send(self: *sh8601, register: Register, data: []const u8) Dbi.Error!void {
    try self.dbi.writeCommand(@intFromEnum(register), data);
}

fn setMemoryAccessControl(self: *sh8601, value: MemoryAccessControl) Dbi.Error!void {
    try self.send(.memory_access_control, &.{value.encode()});
}

fn encodeRange(out: *[4]u8, start: u16, end: u16) void {
    out.* = .{
        @intCast(start >> 8),
        @intCast(start & 0x00FF),
        @intCast(end >> 8),
        @intCast(end & 0x00FF),
    };
}

fn encodeU16(out: *[2]u8, value: u16) void {
    out.* = .{
        @intCast(value >> 8),
        @intCast(value & 0x00FF),
    };
}

pub const Display = struct {
    const Error = DisplaySurface.Error;

    pub const OpenFn = *const fn (controller: *sh8601) Error!void;

    pub const Config = struct {
        allocator: glib.std.mem.Allocator,
        dbi: Dbi,
        delay: Delay,
        controller: sh8601.Config,
        flush: Flush.Config,
        open: ?OpenFn = null,
        initial_brightness: u8 = 255,
    };

    allocator: glib.std.mem.Allocator,
    controller: sh8601,
    flush_config: Flush.Config,
    rgb565_buffer: []u16,
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
            .controller = sh8601.init(config.dbi, config.delay, config.controller),
            .flush_config = config.flush,
            .rgb565_buffer = buffer,
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
            self.controller.setBrightness(self.brightness_level) catch return error.DisplayError;
        } else {
            self.controller.setBrightness(0) catch return error.DisplayError;
            self.controller.displayOff() catch return error.DisplayError;
        }
        self.is_enabled = is_enabled;
    }

    fn enabled(self: *Display) Error!bool {
        return self.is_enabled;
    }

    fn setBrightness(self: *Display, level: u8) Error!void {
        if (self.is_enabled) {
            self.controller.setBrightness(level) catch return error.DisplayError;
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn exposesWvAmoledPanelPreset() !void {
            const config = defaultWvAmoled18Config();
            try grt.std.testing.expectEqual(@as(u16, 368), config.native_width);
            try grt.std.testing.expectEqual(@as(u16, 448), config.native_height);
            try grt.std.testing.expectEqual(@as(u16, 448), config.logical_width);
            try grt.std.testing.expectEqual(@as(u16, 368), config.logical_height);
            try grt.std.testing.expectEqual(PixelFormat.rgb565, config.pixel_format);
            try grt.std.testing.expectEqual(@as(u16, 0x01D1), config.tear_scanline);
            try grt.std.testing.expectEqual(@as(u8, 0x20), config.control_display.encode());
            try grt.std.testing.expectEqual(@as(u8, Qspi.write_command_opcode), 0x02);
            try grt.std.testing.expectEqual(@as(u8, Qspi.write_color_opcode), 0x32);
        }

        fn setBrightnessEmitsBrightnessCommand() !void {
            const FakeBus = struct {
                command: u8 = 0,
                data: [1]u8 = .{0},

                pub fn writeCommand(self: *@This(), command: u8, data: []const u8) Dbi.Error!void {
                    self.command = command;
                    @memcpy(&self.data, data);
                }

                pub fn writeData(_: *@This(), _: []const u8) Dbi.Error!void {}

                pub fn writeCommandData(_: *@This(), _: u8, _: []const u8) Dbi.Error!void {}
            };
            const FakeDelay = struct {
                pub fn sleep(_: *@This(), _: glib.time.duration.Duration) void {}
            };

            var fake_bus = FakeBus{};
            var fake_delay = FakeDelay{};
            var driver = sh8601.init(Dbi.init(&fake_bus), Delay.init(&fake_delay), .{});

            try driver.setBrightness(0x80);

            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.write_display_brightness)), fake_bus.command);
            try grt.std.testing.expectEqual(@as(u8, 0x80), fake_bus.data[0]);
        }

        fn openEmitsSemanticInitializationSequence() !void {
            const FakeBus = struct {
                commands: [16]u8 = [_]u8{0} ** 16,
                data: [16][4]u8 = [_][4]u8{[_]u8{ 0, 0, 0, 0 }} ** 16,
                data_len: [16]usize = [_]usize{0} ** 16,
                count: usize = 0,

                pub fn writeCommand(self: *@This(), command: u8, data: []const u8) Dbi.Error!void {
                    self.commands[self.count] = command;
                    self.data_len[self.count] = data.len;
                    if (data.len != 0) @memcpy(self.data[self.count][0..data.len], data);
                    self.count += 1;
                }

                pub fn writeData(_: *@This(), _: []const u8) Dbi.Error!void {}

                pub fn writeCommandData(_: *@This(), _: u8, _: []const u8) Dbi.Error!void {}
            };
            const FakeDelay = struct {
                calls: usize = 0,

                pub fn sleep(self: *@This(), _: glib.time.duration.Duration) void {
                    self.calls += 1;
                }
            };

            var fake_bus = FakeBus{};
            var fake_delay = FakeDelay{};
            var driver = sh8601.init(Dbi.init(&fake_bus), Delay.init(&fake_delay), .{});

            try driver.open();

            try grt.std.testing.expectEqual(@as(usize, 11), fake_bus.count);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.memory_access_control)), fake_bus.commands[0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.pixel_format_set)), fake_bus.commands[1]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.sleep_out)), fake_bus.commands[2]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.tear_scanline)), fake_bus.commands[3]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x01, 0xD1 }, fake_bus.data[3][0..2]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.tear_effect_line_on)), fake_bus.commands[4]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.write_ctrl_display)), fake_bus.commands[5]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.column_address_set)), fake_bus.commands[6]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x01, 0x6F }, fake_bus.data[6][0..4]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.row_address_set)), fake_bus.commands[7]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x01, 0xBF }, fake_bus.data[7][0..4]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.write_display_brightness)), fake_bus.commands[8]);
            try grt.std.testing.expectEqual(@as(u8, 0x00), fake_bus.data[8][0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.display_on)), fake_bus.commands[9]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.write_display_brightness)), fake_bus.commands[10]);
            try grt.std.testing.expectEqual(@as(u8, 0xFF), fake_bus.data[10][0]);
            try grt.std.testing.expectEqual(@as(usize, 4), fake_delay.calls);
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

            TestCase.exposesWvAmoledPanelPreset() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.setBrightnessEmitsBrightnessCommand() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.openEmitsSemanticInitializationSequence() catch |err| {
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
