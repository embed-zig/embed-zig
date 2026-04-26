//! I2c — non-owning type-erased register/control bus.
//!
//! This wrapper is intentionally narrow for the first `lib/drivers` phase:
//! it only exposes synchronous `write`, `read`, and `writeRead`.
//! It does not own the underlying bus and does not provide downcast hooks.

const glib = @import("glib");

const I2c = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Address = u7;

pub const Error = error{
    Nack,
    BusError,
    ArbitrationLost,
    Timeout,
    Unexpected,
};

pub const VTable = struct {
    write: *const fn (ptr: *anyopaque, addr: Address, data: []const u8) Error!void,
    read: *const fn (ptr: *anyopaque, addr: Address, buf: []u8) Error!void,
    writeRead: *const fn (ptr: *anyopaque, addr: Address, tx: []const u8, rx: []u8) Error!void,
};

pub fn write(self: I2c, addr: Address, data: []const u8) Error!void {
    return self.vtable.write(self.ptr, addr, data);
}

pub fn read(self: I2c, addr: Address, buf: []u8) Error!void {
    return self.vtable.read(self.ptr, addr, buf);
}

pub fn writeRead(self: I2c, addr: Address, tx: []const u8, rx: []u8) Error!void {
    return self.vtable.writeRead(self.ptr, addr, tx, rx);
}

pub fn init(pointer: anytype) I2c {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("I2c.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn writeFn(ptr: *anyopaque, addr: Address, data: []const u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.write(addr, data);
        }

        fn readFn(ptr: *anyopaque, addr: Address, buf: []u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(addr, buf);
        }

        fn writeReadFn(ptr: *anyopaque, addr: Address, tx: []const u8, rx: []u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.writeRead(addr, tx, rx);
        }

        const vtable = VTable{
            .write = writeFn,
            .read = readFn,
            .writeRead = writeReadFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn dispatchesWriteReadAndWriteRead() !void {
            const Fake = struct {
                last_write_addr: Address = 0,
                last_write_len: usize = 0,
                last_write: [8]u8 = [_]u8{0} ** 8,

                last_read_addr: Address = 0,
                last_read_len: usize = 0,
                read_fill: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 },

                last_write_read_addr: Address = 0,
                last_write_read_tx_len: usize = 0,
                last_write_read_tx: [8]u8 = [_]u8{0} ** 8,
                write_read_fill: [4]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD },

                fn write(self: *@This(), addr: Address, data: []const u8) Error!void {
                    self.last_write_addr = addr;
                    self.last_write_len = data.len;
                    @memcpy(self.last_write[0..data.len], data);
                }

                fn read(self: *@This(), addr: Address, buf: []u8) Error!void {
                    self.last_read_addr = addr;
                    self.last_read_len = buf.len;
                    @memcpy(buf, self.read_fill[0..buf.len]);
                }

                fn writeRead(self: *@This(), addr: Address, tx: []const u8, rx: []u8) Error!void {
                    self.last_write_read_addr = addr;
                    self.last_write_read_tx_len = tx.len;
                    @memcpy(self.last_write_read_tx[0..tx.len], tx);
                    @memcpy(rx, self.write_read_fill[0..rx.len]);
                }
            };

            var fake = Fake{};
            const bus = I2c.init(&fake);

            try bus.write(0x1A, &.{ 0x01, 0x02, 0x03 });
            try grt.std.testing.expectEqual(@as(Address, 0x1A), fake.last_write_addr);
            try grt.std.testing.expectEqual(@as(usize, 3), fake.last_write_len);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, fake.last_write[0..3]);

            var read_buf: [2]u8 = undefined;
            try bus.read(0x2B, &read_buf);
            try grt.std.testing.expectEqual(@as(Address, 0x2B), fake.last_read_addr);
            try grt.std.testing.expectEqual(@as(usize, 2), fake.last_read_len);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22 }, &read_buf);

            var rx: [3]u8 = undefined;
            try bus.writeRead(0x3C, &.{ 0x09, 0x0A }, &rx);
            try grt.std.testing.expectEqual(@as(Address, 0x3C), fake.last_write_read_addr);
            try grt.std.testing.expectEqual(@as(usize, 2), fake.last_write_read_tx_len);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x09, 0x0A }, fake.last_write_read_tx[0..2]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, &rx);
        }

        fn propagatesBackendErrors() !void {
            const Fake = struct {
                fail_write: bool = false,
                fail_read: bool = false,
                fail_write_read: bool = false,

                fn write(self: *@This(), _: Address, _: []const u8) Error!void {
                    if (self.fail_write) return error.Timeout;
                }

                fn read(self: *@This(), _: Address, _: []u8) Error!void {
                    if (self.fail_read) return error.BusError;
                }

                fn writeRead(self: *@This(), _: Address, _: []const u8, _: []u8) Error!void {
                    if (self.fail_write_read) return error.Nack;
                }
            };

            var fake = Fake{ .fail_write = true };
            const bus = I2c.init(&fake);
            try grt.std.testing.expectError(error.Timeout, bus.write(0x10, &.{0x00}));

            fake.fail_write = false;
            fake.fail_read = true;
            var buf: [1]u8 = undefined;
            try grt.std.testing.expectError(error.BusError, bus.read(0x10, &buf));

            fake.fail_read = false;
            fake.fail_write_read = true;
            try grt.std.testing.expectError(error.Nack, bus.writeRead(0x10, &.{0x00}, &buf));
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

            TestCase.dispatchesWriteReadAndWriteRead() catch |err| {
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
