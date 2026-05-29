//! Dbi — non-owning type-erased display command/data bus.
//!
//! Display controller drivers use this narrow surface for DBI-style command
//! writes and data phase writes. Board/platform code owns physical bus setup,
//! chip-select policy, transfer queueing, DMA, and power/backlight handling.

const glib = @import("glib");

const Dbi = @This();

pub const Spi = @import("dbi/Spi.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{
    BusError,
    Timeout,
    Unexpected,
};

pub const VTable = struct {
    writeCommand: *const fn (ptr: *anyopaque, command: u8, params: []const u8) Error!void,
    writeData: *const fn (ptr: *anyopaque, data: []const u8) Error!void,
    writeCommandData: *const fn (ptr: *anyopaque, command: u8, data: []const u8) Error!void,
};

pub fn writeCommand(self: Dbi, command: u8, params: []const u8) Error!void {
    return self.vtable.writeCommand(self.ptr, command, params);
}

pub fn writeData(self: Dbi, data: []const u8) Error!void {
    return self.vtable.writeData(self.ptr, data);
}

pub fn writeCommandData(self: Dbi, command: u8, data: []const u8) Error!void {
    return self.vtable.writeCommandData(self.ptr, command, data);
}

pub fn init(pointer: anytype) Dbi {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Dbi.init expects a single-item pointer");

    const Impl = info.pointer.child;

    comptime {
        _ = @as(*const fn (*Impl, u8, []const u8) Error!void, &Impl.writeCommand);
        _ = @as(*const fn (*Impl, []const u8) Error!void, &Impl.writeData);
        _ = @as(*const fn (*Impl, u8, []const u8) Error!void, &Impl.writeCommandData);
    }

    const gen = struct {
        fn writeCommandFn(ptr: *anyopaque, command: u8, params: []const u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.writeCommand(command, params);
        }

        fn writeDataFn(ptr: *anyopaque, data: []const u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.writeData(data);
        }

        fn writeCommandDataFn(ptr: *anyopaque, command: u8, data: []const u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.writeCommandData(command, data);
        }

        const vtable = VTable{
            .writeCommand = writeCommandFn,
            .writeData = writeDataFn,
            .writeCommandData = writeCommandDataFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn dispatchesCommandAndDataWrites() !void {
            const Fake = struct {
                last_command: u8 = 0,
                last_params: [8]u8 = [_]u8{0} ** 8,
                last_params_len: usize = 0,
                last_data: [8]u8 = [_]u8{0} ** 8,
                last_data_len: usize = 0,
                last_command_data_command: u8 = 0,
                last_command_data: [8]u8 = [_]u8{0} ** 8,
                last_command_data_len: usize = 0,

                fn writeCommand(self: *@This(), command: u8, params: []const u8) Error!void {
                    self.last_command = command;
                    self.last_params_len = params.len;
                    @memcpy(self.last_params[0..params.len], params);
                }

                fn writeData(self: *@This(), data: []const u8) Error!void {
                    self.last_data_len = data.len;
                    @memcpy(self.last_data[0..data.len], data);
                }

                fn writeCommandData(self: *@This(), command: u8, data: []const u8) Error!void {
                    self.last_command_data_command = command;
                    self.last_command_data_len = data.len;
                    @memcpy(self.last_command_data[0..data.len], data);
                }
            };

            var fake = Fake{};
            const dbi = Dbi.init(&fake);

            try dbi.writeCommand(0x2A, &.{ 0x00, 0x10, 0x00, 0x20 });
            try dbi.writeData(&.{ 0xAA, 0xBB, 0xCC });
            try dbi.writeCommandData(0x2C, &.{ 0x11, 0x22 });

            try grt.std.testing.expectEqual(@as(u8, 0x2A), fake.last_command);
            try grt.std.testing.expectEqual(@as(usize, 4), fake.last_params_len);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x00, 0x10, 0x00, 0x20 }, fake.last_params[0..4]);
            try grt.std.testing.expectEqual(@as(usize, 3), fake.last_data_len);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, fake.last_data[0..3]);
            try grt.std.testing.expectEqual(@as(u8, 0x2C), fake.last_command_data_command);
            try grt.std.testing.expectEqual(@as(usize, 2), fake.last_command_data_len);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22 }, fake.last_command_data[0..2]);
        }

        fn propagatesBackendErrors() !void {
            const Fake = struct {
                fn writeCommand(_: *@This(), _: u8, _: []const u8) Error!void {
                    return error.Timeout;
                }

                fn writeData(_: *@This(), _: []const u8) Error!void {
                    return error.BusError;
                }

                fn writeCommandData(_: *@This(), _: u8, _: []const u8) Error!void {
                    return error.Unexpected;
                }
            };

            var fake = Fake{};
            const dbi = Dbi.init(&fake);

            try grt.std.testing.expectError(error.Timeout, dbi.writeCommand(0x11, &.{}));
            try grt.std.testing.expectError(error.BusError, dbi.writeData(&.{0x00}));
            try grt.std.testing.expectError(error.Unexpected, dbi.writeCommandData(0x2C, &.{0x00}));
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

            TestCase.dispatchesCommandAndDataWrites() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.propagatesBackendErrors() catch |err| {
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
