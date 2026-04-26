//! Spi — non-owning type-erased synchronous SPI bus.
//!
//! This wrapper intentionally exposes only the operations currently needed by
//! `lib/drivers`: write-only transactions and full-duplex transfers.

const glib = @import("glib");

const Spi = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{
    BusError,
    Timeout,
    Unexpected,
};

pub const VTable = struct {
    write: *const fn (ptr: *anyopaque, data: []const u8) Error!void,
    transfer: *const fn (ptr: *anyopaque, tx: []const u8, rx: []u8) Error!void,
};

pub fn write(self: Spi, data: []const u8) Error!void {
    return self.vtable.write(self.ptr, data);
}

pub fn transfer(self: Spi, tx: []const u8, rx: []u8) Error!void {
    if (tx.len != rx.len) return error.Unexpected;
    return self.vtable.transfer(self.ptr, tx, rx);
}

pub fn init(pointer: anytype) Spi {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Spi.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn writeFn(ptr: *anyopaque, data: []const u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.write(data);
        }

        fn transferFn(ptr: *anyopaque, tx: []const u8, rx: []u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.transfer(tx, rx);
        }

        const vtable = VTable{
            .write = writeFn,
            .transfer = transferFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn dispatchesWriteAndTransfer() !void {
            const Fake = struct {
                last_write: [8]u8 = [_]u8{0} ** 8,
                last_write_len: usize = 0,

                last_transfer_tx: [8]u8 = [_]u8{0} ** 8,
                last_transfer_len: usize = 0,
                transfer_fill: [4]u8 = .{ 0x21, 0x43, 0x65, 0x87 },

                fn write(self: *@This(), data: []const u8) Error!void {
                    self.last_write_len = data.len;
                    @memcpy(self.last_write[0..data.len], data);
                }

                fn transfer(self: *@This(), tx: []const u8, rx: []u8) Error!void {
                    self.last_transfer_len = tx.len;
                    @memcpy(self.last_transfer_tx[0..tx.len], tx);
                    @memcpy(rx, self.transfer_fill[0..rx.len]);
                }
            };

            var fake = Fake{};
            const spi = Spi.init(&fake);

            try spi.write(&.{ 0xAA, 0xBB, 0xCC });
            try lib.testing.expectEqual(@as(usize, 3), fake.last_write_len);
            try lib.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, fake.last_write[0..3]);

            var rx: [3]u8 = undefined;
            try spi.transfer(&.{ 0x10, 0x20, 0x30 }, &rx);
            try lib.testing.expectEqual(@as(usize, 3), fake.last_transfer_len);
            try lib.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30 }, fake.last_transfer_tx[0..3]);
            try lib.testing.expectEqualSlices(u8, &.{ 0x21, 0x43, 0x65 }, &rx);
        }

        fn propagatesErrorsAndRejectsMismatchedTransferLengths() !void {
            const Fake = struct {
                fail_write: bool = false,
                fail_transfer: bool = false,

                fn write(self: *@This(), _: []const u8) Error!void {
                    if (self.fail_write) return error.Timeout;
                }

                fn transfer(self: *@This(), _: []const u8, _: []u8) Error!void {
                    if (self.fail_transfer) return error.BusError;
                }
            };

            var fake = Fake{ .fail_write = true };
            const spi = Spi.init(&fake);
            try lib.testing.expectError(error.Timeout, spi.write(&.{0x00}));

            fake.fail_write = false;
            fake.fail_transfer = true;
            var rx: [1]u8 = undefined;
            try lib.testing.expectError(error.BusError, spi.transfer(&.{0x00}, &rx));

            fake.fail_transfer = false;
            var rx2: [2]u8 = undefined;
            try lib.testing.expectError(error.Unexpected, spi.transfer(&.{0x00}, &rx2));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.dispatchesWriteAndTransfer() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.propagatesErrorsAndRejectsMismatchedTransferLengths() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
