//! SPI-backed DBI command/data adapter.
//!
//! The caller owns SPI host/device setup and chip-select policy. This adapter
//! only toggles the DC GPIO around synchronous SPI writes.

const glib = @import("glib");

const Gpio = @import("../../Gpio.zig");
const Spi = @import("../../Spi.zig");
const Dbi = @import("../Dbi.zig");

const SpiDbi = @This();

spi: Spi,
dc: Gpio,
config: Config = .{},

pub const Config = struct {
    command_level: Gpio.Level = .low,
    data_level: Gpio.Level = .high,
};

pub fn init(spi: Spi, dc: Gpio, config: Config) SpiDbi {
    return .{
        .spi = spi,
        .dc = dc,
        .config = config,
    };
}

pub fn asDbi(self: *SpiDbi) Dbi {
    return Dbi.init(self);
}

pub fn writeCommand(self: *SpiDbi, command: u8, params: []const u8) Dbi.Error!void {
    self.dc.write(self.config.command_level) catch return error.BusError;
    self.spi.write(&.{command}) catch |err| return mapSpiError(err);

    if (params.len == 0) return;
    self.dc.write(self.config.data_level) catch return error.BusError;
    self.spi.write(params) catch |err| return mapSpiError(err);
}

pub fn writeData(self: *SpiDbi, data: []const u8) Dbi.Error!void {
    if (data.len == 0) return;
    self.dc.write(self.config.data_level) catch return error.BusError;
    self.spi.write(data) catch |err| return mapSpiError(err);
}

pub fn writeCommandData(self: *SpiDbi, command: u8, data: []const u8) Dbi.Error!void {
    try self.writeCommand(command, &.{});
    try self.writeData(data);
}

fn mapSpiError(err: Spi.Error) Dbi.Error {
    return switch (err) {
        error.BusError => error.BusError,
        error.Timeout => error.Timeout,
        error.Unexpected => error.Unexpected,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn commandWriteTogglesDcAndWritesCommandThenParams() !void {
            const FakeSpi = struct {
                writes: [4][8]u8 = [_][8]u8{[_]u8{0} ** 8} ** 4,
                write_lens: [4]usize = .{ 0, 0, 0, 0 },
                write_count: usize = 0,

                pub fn write(self: *@This(), data: []const u8) Spi.Error!void {
                    self.write_lens[self.write_count] = data.len;
                    @memcpy(self.writes[self.write_count][0..data.len], data);
                    self.write_count += 1;
                }

                pub fn transfer(_: *@This(), _: []const u8, _: []u8) Spi.Error!void {
                    return error.Unexpected;
                }
            };

            const FakeGpio = struct {
                levels: [4]Gpio.Level = .{ .low, .low, .low, .low },
                write_count: usize = 0,

                pub fn read(self: *@This()) Gpio.Error!Gpio.Level {
                    return self.levels[self.write_count];
                }

                pub fn write(self: *@This(), level: Gpio.Level) Gpio.Error!void {
                    self.levels[self.write_count] = level;
                    self.write_count += 1;
                }

                pub fn setDirection(_: *@This(), _: Gpio.Direction) Gpio.Error!void {}
            };

            var fake_spi = FakeSpi{};
            var fake_dc = FakeGpio{};
            var adapter = SpiDbi.init(Spi.init(&fake_spi), Gpio.init(&fake_dc), .{});
            const dbi = adapter.asDbi();

            try dbi.writeCommand(0x2A, &.{ 0x00, 0x10, 0x00, 0x20 });

            try grt.std.testing.expectEqual(@as(usize, 2), fake_dc.write_count);
            try grt.std.testing.expectEqual(Gpio.Level.low, fake_dc.levels[0]);
            try grt.std.testing.expectEqual(Gpio.Level.high, fake_dc.levels[1]);
            try grt.std.testing.expectEqual(@as(usize, 2), fake_spi.write_count);
            try grt.std.testing.expectEqualSlices(u8, &.{0x2A}, fake_spi.writes[0][0..fake_spi.write_lens[0]]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x00, 0x10, 0x00, 0x20 }, fake_spi.writes[1][0..fake_spi.write_lens[1]]);
        }

        fn commandDataWriteSendsCommandThenData() !void {
            const FakeSpi = struct {
                writes: [2][8]u8 = [_][8]u8{[_]u8{0} ** 8} ** 2,
                write_lens: [2]usize = .{ 0, 0 },
                write_count: usize = 0,

                pub fn write(self: *@This(), data: []const u8) Spi.Error!void {
                    self.write_lens[self.write_count] = data.len;
                    @memcpy(self.writes[self.write_count][0..data.len], data);
                    self.write_count += 1;
                }

                pub fn transfer(_: *@This(), _: []const u8, _: []u8) Spi.Error!void {
                    return error.Unexpected;
                }
            };

            const FakeGpio = struct {
                levels: [2]Gpio.Level = .{ .low, .low },
                write_count: usize = 0,

                pub fn read(self: *@This()) Gpio.Error!Gpio.Level {
                    return self.levels[self.write_count];
                }

                pub fn write(self: *@This(), level: Gpio.Level) Gpio.Error!void {
                    self.levels[self.write_count] = level;
                    self.write_count += 1;
                }

                pub fn setDirection(_: *@This(), _: Gpio.Direction) Gpio.Error!void {}
            };

            var fake_spi = FakeSpi{};
            var fake_dc = FakeGpio{};
            var adapter = SpiDbi.init(Spi.init(&fake_spi), Gpio.init(&fake_dc), .{});

            try adapter.writeCommandData(0x2C, &.{ 0xAA, 0xBB });

            try grt.std.testing.expectEqual(@as(usize, 2), fake_dc.write_count);
            try grt.std.testing.expectEqual(Gpio.Level.low, fake_dc.levels[0]);
            try grt.std.testing.expectEqual(Gpio.Level.high, fake_dc.levels[1]);
            try grt.std.testing.expectEqual(@as(usize, 2), fake_spi.write_count);
            try grt.std.testing.expectEqualSlices(u8, &.{0x2C}, fake_spi.writes[0][0..fake_spi.write_lens[0]]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, fake_spi.writes[1][0..fake_spi.write_lens[1]]);
        }

        fn dataWriteUsesDataLevelOnly() !void {
            const FakeSpi = struct {
                last_write: [8]u8 = [_]u8{0} ** 8,
                last_write_len: usize = 0,

                pub fn write(self: *@This(), data: []const u8) Spi.Error!void {
                    self.last_write_len = data.len;
                    @memcpy(self.last_write[0..data.len], data);
                }

                pub fn transfer(_: *@This(), _: []const u8, _: []u8) Spi.Error!void {
                    return error.Unexpected;
                }
            };

            const FakeGpio = struct {
                last_level: Gpio.Level = .low,
                write_count: usize = 0,

                pub fn read(self: *@This()) Gpio.Error!Gpio.Level {
                    return self.last_level;
                }

                pub fn write(self: *@This(), level: Gpio.Level) Gpio.Error!void {
                    self.last_level = level;
                    self.write_count += 1;
                }

                pub fn setDirection(_: *@This(), _: Gpio.Direction) Gpio.Error!void {}
            };

            var fake_spi = FakeSpi{};
            var fake_dc = FakeGpio{};
            var adapter = SpiDbi.init(Spi.init(&fake_spi), Gpio.init(&fake_dc), .{});

            try adapter.writeData(&.{ 0xAA, 0xBB });

            try grt.std.testing.expectEqual(@as(usize, 1), fake_dc.write_count);
            try grt.std.testing.expectEqual(Gpio.Level.high, fake_dc.last_level);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, fake_spi.last_write[0..fake_spi.last_write_len]);
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

            TestCase.commandWriteTogglesDcAndWritesCommandThenParams() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.commandDataWriteSendsCommandThenData() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.dataWriteUsesDataLevelOnly() catch |err| {
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
