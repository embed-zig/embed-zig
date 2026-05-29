//! ST7789 SPI TFT LCD controller driver.
//!
//! The driver owns ST7789 command names and command encoding. Board/platform
//! code owns SPI host setup, chip-select GPIO policy, transfer queueing, DMA,
//! and backlight.

const glib = @import("glib");

const DisplaySurface = @import("../Display.zig");
const Delay = @import("../Delay.zig");
const Dbi = @import("Dbi.zig");
const Flush = @import("Flush.zig");
const Rgb = @import("Rgb.zig");

const st7789 = @This();

pub const Register = enum(u8) {
    software_reset = 0x01,
    sleep_in = 0x10,
    sleep_out = 0x11,
    inversion_off = 0x20,
    inversion_on = 0x21,
    display_off = 0x28,
    display_on = 0x29,
    column_address_set = 0x2A,
    row_address_set = 0x2B,
    memory_write = 0x2C,
    memory_access_control = 0x36,
    pixel_format_set = 0x3A,
    ram_control = 0xB0,
};

pub const ResetMode = enum {
    none,
    software,
};

pub const RgbOrder = enum {
    rgb,
    bgr,

    pub fn encodeMadctl(self: RgbOrder) u8 {
        return switch (self) {
            .rgb => 0,
            .bgr => Madctl.BGR,
        };
    }
};

pub const PixelFormat = enum(u8) {
    rgb565 = 0x55,
    rgb666 = 0x66,
};

pub const Orientation = struct {
    swap_xy: bool = false,
    mirror_x: bool = false,
    mirror_y: bool = false,

    pub fn encodeMadctl(self: Orientation) u8 {
        var value: u8 = 0;
        if (self.mirror_y) value |= Madctl.MY;
        if (self.mirror_x) value |= Madctl.MX;
        if (self.swap_xy) value |= Madctl.MV;
        return value;
    }
};

pub const Madctl = struct {
    pub const MY: u8 = 0x80;
    pub const MX: u8 = 0x40;
    pub const MV: u8 = 0x20;
    pub const ML: u8 = 0x10;
    pub const BGR: u8 = 0x08;
    pub const MH: u8 = 0x04;
};

pub const DataEndian = enum {
    big,
    little,
};

pub const RamControl = struct {
    pub const RGB_ENDIAN: u8 = 0x08;
    pub const DBI_ENDIAN: u8 = 0x04;

    pub fn encode(endian: DataEndian) [2]u8 {
        return .{ 0x00, if (endian == .little) 0xF0 | RGB_ENDIAN else 0xF0 };
    }
};

pub const Config = struct {
    width: u16,
    height: u16,
    reset: ResetMode = .none,
    rgb_order: RgbOrder = .rgb,
    orientation: Orientation = .{},
    pixel_format: PixelFormat = .rgb565,
    data_endian: DataEndian = .big,
    invert_color: bool = false,
    reset_delay_ms: u16 = 20,
    sleep_out_delay_ms: u16 = 100,
};

dbi: Dbi,
delay: Delay,
config: Config,
is_open: bool = false,
madctl: u8 = 0,

pub fn init(dbi: Dbi, delay: Delay, config: Config) st7789 {
    return .{
        .dbi = dbi,
        .delay = delay,
        .config = config,
    };
}

pub fn open(self: *st7789) Dbi.Error!void {
    self.madctl = self.config.rgb_order.encodeMadctl();
    if (self.config.reset == .software) {
        try self.softwareReset();
    }
    try self.sleepOut();
    try self.writeMemoryAccessControl();
    try self.setPixelFormat(self.config.pixel_format);
    try self.setRamControl(self.config.data_endian);
    try self.setInversion(self.config.invert_color);
    try self.setSwapXY(self.config.orientation.swap_xy);
    try self.setMirror(self.config.orientation.mirror_x, self.config.orientation.mirror_y);
    try self.displayOn();
    self.is_open = true;
}

pub fn softwareReset(self: *st7789) Dbi.Error!void {
    try self.send(.software_reset, &.{});
    self.delay.sleep(@as(glib.time.duration.Duration, self.config.reset_delay_ms) * glib.time.duration.MilliSecond);
}

pub fn sleepOut(self: *st7789) Dbi.Error!void {
    try self.send(.sleep_out, &.{});
    self.delay.sleep(@as(glib.time.duration.Duration, self.config.sleep_out_delay_ms) * glib.time.duration.MilliSecond);
}

pub fn displayOn(self: *st7789) Dbi.Error!void {
    try self.send(.display_on, &.{});
}

pub fn displayOff(self: *st7789) Dbi.Error!void {
    try self.send(.display_off, &.{});
}

pub fn setPixelFormat(self: *st7789, format: PixelFormat) Dbi.Error!void {
    try self.send(.pixel_format_set, &.{@intFromEnum(format)});
}

pub fn setMemoryAccessControl(self: *st7789, orientation: Orientation) Dbi.Error!void {
    self.madctl = self.config.rgb_order.encodeMadctl() | orientation.encodeMadctl();
    try self.writeMemoryAccessControl();
}

pub fn setInversion(self: *st7789, enabled: bool) Dbi.Error!void {
    try self.send(if (enabled) .inversion_on else .inversion_off, &.{});
}

pub fn setMirror(self: *st7789, mirror_x: bool, mirror_y: bool) Dbi.Error!void {
    if (mirror_x) {
        self.madctl |= Madctl.MX;
    } else {
        self.madctl &= ~Madctl.MX;
    }
    if (mirror_y) {
        self.madctl |= Madctl.MY;
    } else {
        self.madctl &= ~Madctl.MY;
    }
    try self.writeMemoryAccessControl();
}

pub fn setSwapXY(self: *st7789, enabled: bool) Dbi.Error!void {
    if (enabled) {
        self.madctl |= Madctl.MV;
    } else {
        self.madctl &= ~Madctl.MV;
    }
    try self.writeMemoryAccessControl();
}

pub fn setRamControl(self: *st7789, endian: DataEndian) Dbi.Error!void {
    const data = RamControl.encode(endian);
    try self.send(.ram_control, &data);
}

pub fn setAddressWindow(self: *st7789, x0: u16, y0: u16, x1: u16, y1: u16) Dbi.Error!void {
    var column: [4]u8 = undefined;
    var row: [4]u8 = undefined;
    encodeRange(&column, x0, x1);
    encodeRange(&row, y0, y1);
    try self.send(.column_address_set, &column);
    try self.send(.row_address_set, &row);
}

pub fn writeMemory(self: *st7789) Dbi.Error!void {
    try self.send(.memory_write, &.{});
}

pub fn writeMemoryData(self: *st7789, data: []const u8) Dbi.Error!void {
    try self.dbi.writeCommandData(@intFromEnum(Register.memory_write), data);
}

fn send(self: *st7789, register: Register, data: []const u8) Dbi.Error!void {
    try self.dbi.writeCommand(@intFromEnum(register), data);
}

fn writeMemoryAccessControl(self: *st7789) Dbi.Error!void {
    try self.send(.memory_access_control, &.{self.madctl});
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

    pub const OpenFn = *const fn (controller: *st7789) Error!void;
    pub const BrightnessFn = *const fn (level: u8) Error!void;

    pub const Config = struct {
        allocator: glib.std.mem.Allocator,
        dbi: Dbi,
        delay: Delay,
        controller: st7789.Config,
        flush: Flush.Config,
        open: ?OpenFn = null,
        set_brightness: ?BrightnessFn = null,
        initial_brightness: u8 = 255,
    };

    allocator: glib.std.mem.Allocator,
    controller: st7789,
    flush_config: Flush.Config,
    rgb565_buffer: []u16,
    set_brightness: ?BrightnessFn,
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
            .controller = st7789.init(config.dbi, config.delay, config.controller),
            .flush_config = config.flush,
            .rgb565_buffer = buffer,
            .set_brightness = config.set_brightness,
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
        fn storesPanelConfig() !void {
            const config = panelConfig();
            try grt.std.testing.expectEqual(@as(u16, 320), config.width);
            try grt.std.testing.expectEqual(@as(u16, 240), config.height);
            try grt.std.testing.expect(config.orientation.swap_xy);
            try grt.std.testing.expect(config.orientation.mirror_x);
            try grt.std.testing.expect(!config.orientation.mirror_y);
            try grt.std.testing.expectEqual(PixelFormat.rgb565, config.pixel_format);
            try grt.std.testing.expectEqual(DataEndian.big, config.data_endian);
            try grt.std.testing.expect(config.invert_color);
        }

        fn orientationEncodesMadctlBits() !void {
            const orientation = Orientation{
                .swap_xy = true,
                .mirror_x = true,
                .mirror_y = false,
            };
            try grt.std.testing.expectEqual(@as(u8, Madctl.MV | Madctl.MX), orientation.encodeMadctl());
        }

        fn openEmitsInitializationCommands() !void {
            const FakeBus = struct {
                commands: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                data: [8][2]u8 = [_][2]u8{.{ 0, 0 }} ** 8,
                data_len: [8]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                command_data_command: u8 = 0,
                command_data_len: usize = 0,
                count: usize = 0,

                pub fn writeCommand(self: *@This(), command: u8, data: []const u8) Dbi.Error!void {
                    self.commands[self.count] = command;
                    self.data_len[self.count] = data.len;
                    if (data.len != 0) @memcpy(self.data[self.count][0..data.len], data);
                    self.count += 1;
                }

                pub fn writeData(_: *@This(), _: []const u8) Dbi.Error!void {}

                pub fn writeCommandData(self: *@This(), command: u8, data: []const u8) Dbi.Error!void {
                    self.command_data_command = command;
                    self.command_data_len = data.len;
                }
            };
            const FakeDelay = struct {
                calls: usize = 0,

                pub fn sleep(self: *@This(), _: glib.time.duration.Duration) void {
                    self.calls += 1;
                }
            };

            var fake_bus = FakeBus{};
            var fake_delay = FakeDelay{};
            var driver = st7789.init(Dbi.init(&fake_bus), Delay.init(&fake_delay), panelConfig());

            try driver.open();

            try grt.std.testing.expectEqual(@as(usize, 8), fake_bus.count);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.sleep_out)), fake_bus.commands[0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.memory_access_control)), fake_bus.commands[1]);
            try grt.std.testing.expectEqual(panelConfig().rgb_order.encodeMadctl(), fake_bus.data[1][0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.pixel_format_set)), fake_bus.commands[2]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(PixelFormat.rgb565)), fake_bus.data[2][0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.ram_control)), fake_bus.commands[3]);
            try grt.std.testing.expectEqualSlices(u8, &RamControl.encode(.big), fake_bus.data[3][0..2]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.inversion_on)), fake_bus.commands[4]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.memory_access_control)), fake_bus.commands[5]);
            try grt.std.testing.expectEqual(panelConfig().rgb_order.encodeMadctl() | Madctl.MV, fake_bus.data[5][0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.memory_access_control)), fake_bus.commands[6]);
            try grt.std.testing.expectEqual(panelConfig().rgb_order.encodeMadctl() | panelConfig().orientation.encodeMadctl(), fake_bus.data[6][0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.display_on)), fake_bus.commands[7]);
            try grt.std.testing.expectEqual(@as(usize, 1), fake_delay.calls);
        }

        fn panelConfig() Config {
            return .{
                .width = 320,
                .height = 240,
                .orientation = .{
                    .swap_xy = true,
                    .mirror_x = true,
                },
                .data_endian = .big,
                .invert_color = true,
            };
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

            TestCase.storesPanelConfig() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.orientationEncodesMadctlBits() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.openEmitsInitializationCommands() catch |err| {
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
