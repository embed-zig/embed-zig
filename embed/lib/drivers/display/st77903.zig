//! ST77903 QSPI TFT LCD controller driver.
//!
//! The controller driver owns ST77903 command/register names and panel init
//! presets. Platform code owns the physical QSPI controller, DMA/frame policy,
//! reset pin, power rails, and backlight.

const glib = @import("glib");

const DisplaySurface = @import("../Display.zig");
const Delay = @import("../Delay.zig");
const Dbi = @import("Dbi.zig");
const Flush = @import("Flush.zig");
const Rgb = @import("Rgb.zig");

const st77903 = @This();

const Register = enum(u8) {
    sleep_out = 0x11,
    inversion_on = 0x21,
    display_off = 0x28,
    display_on = 0x29,
    column_address_set = 0x2A,
    row_address_set = 0x2B,
    memory_write = 0x2C,
    memory_access_control = 0x36,
    pixel_format_set = 0x3A,
    tear_effect_line_on = 0x35,
    vendor_f0 = 0xF0,
    vendor_e9 = 0xE9,
    vendor_e7 = 0xE7,
    vendor_c1 = 0xC1,
    vendor_c2 = 0xC2,
    vendor_c3 = 0xC3,
    vendor_c4 = 0xC4,
    vendor_c5 = 0xC5,
    vendor_e0 = 0xE0,
    vendor_e1 = 0xE1,
    vendor_e5 = 0xE5,
    vendor_e6 = 0xE6,
    vendor_ec = 0xEC,
    vendor_b2 = 0xB2,
    vendor_b3 = 0xB3,
    vendor_b4 = 0xB4,
    vendor_b5 = 0xB5,
    vendor_a5 = 0xA5,
    vendor_a6 = 0xA6,
    vendor_ba = 0xBA,
    vendor_bb = 0xBB,
    vendor_bc = 0xBC,
    vendor_bd = 0xBD,
};

pub const Qspi = struct {
    pub const reg_write_command: u8 = 0xDE;
    pub const reg_read_command: u8 = 0xDD;
    pub const hsync_command: u8 = 0x60;
    pub const vsync_command: u8 = 0x61;
    pub const h0165y008t_pixel_write_command = [_]u8{ 0xDE, 0x00, 0x60, 0x00 };
};

pub const PixelFormat = enum(u8) {
    rgb565 = 0x05,
    rgb888 = 0x07,
};

pub const MemoryAccessControl = struct {
    value: u8 = 0x0C,

    pub fn encode(self: MemoryAccessControl) u8 {
        return self.value;
    }
};

pub const Config = struct {
    native_width: u16 = 400,
    native_height: u16 = 400,
    logical_width: u16 = 400,
    logical_height: u16 = 400,
    memory_access_control: MemoryAccessControl = .{},
    pixel_format: PixelFormat = .rgb565,
    init_preset: InitPreset = .h0165y008t,
};

pub const InitPreset = enum {
    none,
    h0165y008t,
};

const InitCommand = union(enum) {
    delay_ms: u16,
    write: struct {
        command: Register,
        data: []const u8 = &.{},
    },
};

const h0165y008t_init_commands = [_]InitCommand{
    .{ .delay_ms = 20 },
    .{ .delay_ms = 120 },
    cmd(.vendor_f0, &.{0xC3}),
    cmd(.vendor_f0, &.{0x96}),
    cmd(.vendor_f0, &.{0xA5}),
    cmd(.vendor_e9, &.{0x20}),
    cmd(.vendor_e7, &.{ 0x80, 0x77, 0x1F, 0xCC }),
    cmd(.vendor_c1, &.{ 0x77, 0x07, 0xCF, 0x16 }),
    cmd(.vendor_c2, &.{ 0x77, 0x07, 0xCF, 0x16 }),
    cmd(.vendor_c3, &.{ 0x22, 0x02, 0x22, 0x04 }),
    cmd(.vendor_c4, &.{ 0x22, 0x02, 0x22, 0x04 }),
    cmd(.vendor_c5, &.{0xED}),
    cmd(.vendor_e0, &.{ 0x87, 0x09, 0x0C, 0x06, 0x05, 0x03, 0x29, 0x32, 0x49, 0x0F, 0x1B, 0x17, 0x2A, 0x2F }),
    cmd(.vendor_e1, &.{ 0x87, 0x09, 0x0C, 0x06, 0x05, 0x03, 0x29, 0x32, 0x49, 0x0F, 0x1B, 0x17, 0x2A, 0x2F }),
    cmd(.vendor_e5, &.{ 0xBE, 0xF5, 0xB1, 0x22, 0x22, 0x25, 0x10, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22 }),
    cmd(.vendor_e6, &.{ 0xBE, 0xF5, 0xB1, 0x22, 0x22, 0x25, 0x10, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22 }),
    cmd(.vendor_ec, &.{ 0x40, 0x03 }),
    cmd(.memory_access_control, &.{0x0C}),
    cmd(.pixel_format_set, &.{0x05}),
    cmd(.vendor_b2, &.{0x00}),
    cmd(.vendor_b3, &.{0x01}),
    cmd(.vendor_b4, &.{0x00}),
    cmd(.vendor_b5, &.{ 0x00, 0x08, 0x00, 0x08 }),
    cmd(.vendor_a5, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x15, 0x2A, 0x8A, 0x02 }),
    cmd(.vendor_a6, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x15, 0x2A, 0x8A, 0x02 }),
    cmd(.vendor_ba, &.{ 0x0A, 0x5A, 0x23, 0x10, 0x25, 0x02, 0x00 }),
    cmd(.vendor_bb, &.{ 0x00, 0x30, 0x00, 0x2C, 0x82, 0x87, 0x18, 0x00 }),
    cmd(.vendor_bc, &.{ 0x00, 0x30, 0x00, 0x2C, 0x82, 0x87, 0x18, 0x00 }),
    cmd(.vendor_bd, &.{ 0xA1, 0xB2, 0x2B, 0x1A, 0x56, 0x43, 0x34, 0x65, 0xFF, 0xFF, 0x0F }),
    cmd(.tear_effect_line_on, &.{0x00}),
    cmd(.inversion_on, &.{}),
    cmd(.sleep_out, &.{}),
    .{ .delay_ms = 120 },
    cmd(.display_on, &.{}),
};

dbi: Dbi,
delay: Delay,
config: Config,
is_open: bool = false,

pub fn init(dbi: Dbi, delay: Delay, config: Config) st77903 {
    return .{
        .dbi = dbi,
        .delay = delay,
        .config = config,
    };
}

pub fn defaultH0165Y008TConfig() Config {
    return .{};
}

pub fn defaultH0165Y008TFlushConfig(max_flush_rows: u16) Flush.Config {
    const config = defaultH0165Y008TConfig();
    return .{
        .native_width = config.native_width,
        .native_height = config.native_height,
        .logical_width = config.logical_width,
        .logical_height = config.logical_height,
        .max_flush_rows = max_flush_rows,
        .rgb565_byte_order = .swapped,
    };
}

pub fn open(self: *st77903) Dbi.Error!void {
    switch (self.config.init_preset) {
        .none => {},
        .h0165y008t => try self.openH0165Y008T(),
    }
    self.is_open = true;
}

pub fn displayOn(self: *st77903) Dbi.Error!void {
    try self.send(.display_on, &.{});
}

pub fn displayOff(self: *st77903) Dbi.Error!void {
    try self.send(.display_off, &.{});
}

pub fn setAddressWindow(self: *st77903, x0: u16, y0: u16, x1: u16, y1: u16) Dbi.Error!void {
    var column: [4]u8 = undefined;
    var row: [4]u8 = undefined;
    encodeRange(&column, x0, x1);
    encodeRange(&row, y0, y1);
    try self.send(.column_address_set, &column);
    try self.send(.row_address_set, &row);
}

pub fn writeMemoryData(self: *st77903, data: []const u8) Dbi.Error!void {
    try self.dbi.writeCommandData(@intFromEnum(Register.memory_write), data);
}

fn openH0165Y008T(self: *st77903) Dbi.Error!void {
    for (h0165y008t_init_commands) |step| {
        switch (step) {
            .delay_ms => |ms| self.delay.sleep(@as(glib.time.duration.Duration, ms) * glib.time.duration.MilliSecond),
            .write => |write| try self.send(write.command, write.data),
        }
    }
}

fn send(self: *st77903, register: Register, data: []const u8) Dbi.Error!void {
    try self.dbi.writeCommand(@intFromEnum(register), data);
}

fn encodeRange(out: *[4]u8, start: u16, end: u16) void {
    out.* = .{
        @intCast(start >> 8),
        @intCast(start & 0x00FF),
        @intCast(end >> 8),
        @intCast(end & 0x00FF),
    };
}

fn cmd(command: Register, data: []const u8) InitCommand {
    return .{ .write = .{ .command = command, .data = data } };
}

pub const Display = struct {
    const Error = DisplaySurface.Error;

    pub const OpenFn = *const fn (controller: *st77903) Error!void;
    pub const DeinitFn = *const fn () void;
    pub const BrightnessFn = *const fn (level: u8) Error!void;
    pub const FlushRgb565Fn = *const fn (x: u16, y: u16, w: u16, h: u16, pixels: []const u16) Error!void;

    pub const Config = struct {
        allocator: glib.std.mem.Allocator,
        dbi: Dbi,
        delay: Delay,
        controller: st77903.Config,
        flush: Flush.Config,
        open: ?OpenFn = null,
        deinit: ?DeinitFn = null,
        set_brightness: ?BrightnessFn = null,
        flush_rgb565: ?FlushRgb565Fn = null,
        initial_brightness: u8 = 255,
    };

    allocator: glib.std.mem.Allocator,
    controller: st77903,
    flush_config: Flush.Config,
    rgb565_buffer: []u16,
    deinit_platform: ?DeinitFn,
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
            .controller = st77903.init(config.dbi, config.delay, config.controller),
            .flush_config = config.flush,
            .rgb565_buffer = buffer,
            .deinit_platform = config.deinit,
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
        if (self.deinit_platform) |deinit_platform| deinit_platform();
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
            return flush_rgb565(area.x, area.y, area.w, area.h, chunk);
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn exposesH0165Y008TConfig() !void {
            const config = defaultH0165Y008TConfig();
            const flush = defaultH0165Y008TFlushConfig(16);

            try grt.std.testing.expectEqual(@as(u16, 400), config.native_width);
            try grt.std.testing.expectEqual(@as(u16, 400), config.native_height);
            try grt.std.testing.expectEqual(PixelFormat.rgb565, config.pixel_format);
            try grt.std.testing.expectEqual(@as(u8, 0xDE), Qspi.reg_write_command);
            try grt.std.testing.expectEqual(Flush.Rgb565ByteOrder.swapped, flush.rgb565_byte_order);
        }

        fn openEmitsH0165Y008TPreset() !void {
            const FakeBus = struct {
                commands: [64]u8 = [_]u8{0} ** 64,
                data_len: [64]usize = [_]usize{0} ** 64,
                count: usize = 0,

                pub fn writeCommand(self: *@This(), command: u8, data: []const u8) Dbi.Error!void {
                    self.commands[self.count] = command;
                    self.data_len[self.count] = data.len;
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
            var driver = st77903.init(Dbi.init(&fake_bus), Delay.init(&fake_delay), defaultH0165Y008TConfig());

            try driver.open();

            try grt.std.testing.expectEqual(@as(usize, h0165y008t_init_commands.len - 3), fake_bus.count);
            try grt.std.testing.expectEqual(@as(usize, 3), fake_delay.calls);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.vendor_f0)), fake_bus.commands[0]);
            try grt.std.testing.expectEqual(@as(u8, @intFromEnum(Register.display_on)), fake_bus.commands[fake_bus.count - 1]);
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

            TestCase.exposesH0165Y008TConfig() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.openEmitsH0165Y008TPreset() catch |err| {
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
