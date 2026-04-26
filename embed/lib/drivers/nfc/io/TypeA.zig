//! TypeA — non-owning type-erased ISO14443A frame exchange seam.
//!
//! This contract is intentionally protocol-shaped rather than chip-shaped. It
//! exists so Type A / NTAG helpers can be shared across reader chips without
//! introducing a generic reader object.

const glib = @import("glib");

const TypeA = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const max_timeout_ms: u32 = 30_000;

pub const Error = error{
    Timeout,
    Nack,
    BusError,
    ArbitrationLost,
    InvalidState,
    InvalidArgument,
    Protocol,
    Unexpected,
};

pub const Exchange = struct {
    tx: []const u8,
    tx_bits: usize,
    timeout_ms: u32,
    tx_crc: bool = false,
    rx_crc: bool = false,
    reset_collision: bool = false,
};

pub const VTable = struct {
    transceive: *const fn (ptr: *anyopaque, exchange: Exchange, rx: []u8) Error!usize,
};

pub fn transceive(self: TypeA, exchange: Exchange, rx: []u8) Error!usize {
    if (exchange.tx.len == 0) return error.InvalidArgument;
    if (exchange.tx_bits == 0) return error.InvalidArgument;
    if (exchange.timeout_ms == 0) return error.InvalidArgument;
    if (exchange.timeout_ms > max_timeout_ms) return error.InvalidArgument;
    if (exchange.tx_bits > exchange.tx.len * 8) return error.InvalidArgument;
    return self.vtable.transceive(self.ptr, exchange, rx);
}

pub fn init(pointer: anytype) TypeA {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("TypeA.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn transceiveFn(ptr: *anyopaque, exchange: Exchange, rx: []u8) Error!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.transceive(exchange, rx);
        }

        const vtable = VTable{
            .transceive = transceiveFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn dispatchesTransceiveWithExchangeFlags() !void {
            const Fake = struct {
                last_tx: [8]u8 = [_]u8{0} ** 8,
                last_tx_len: usize = 0,
                last_tx_bits: usize = 0,
                last_timeout_ms: u32 = 0,
                last_tx_crc: bool = false,
                last_rx_crc: bool = false,
                last_reset_collision: bool = false,

                fn transceive(self: *@This(), exchange: Exchange, rx: []u8) Error!usize {
                    self.last_tx_len = exchange.tx.len;
                    self.last_tx_bits = exchange.tx_bits;
                    self.last_timeout_ms = exchange.timeout_ms;
                    self.last_tx_crc = exchange.tx_crc;
                    self.last_rx_crc = exchange.rx_crc;
                    self.last_reset_collision = exchange.reset_collision;
                    @memcpy(self.last_tx[0..exchange.tx.len], exchange.tx);
                    rx[0] = 0x44;
                    rx[1] = 0x00;
                    return 16;
                }
            };

            var fake = Fake{};
            const type_a = TypeA.init(&fake);
            var rx: [2]u8 = undefined;

            const bits = try type_a.transceive(.{
                .tx = &.{0x26},
                .tx_bits = 7,
                .timeout_ms = 1,
                .tx_crc = false,
                .rx_crc = false,
                .reset_collision = true,
            }, &rx);

            try grt.std.testing.expectEqual(@as(usize, 16), bits);
            try grt.std.testing.expectEqual(@as(usize, 1), fake.last_tx_len);
            try grt.std.testing.expectEqual(@as(usize, 7), fake.last_tx_bits);
            try grt.std.testing.expectEqual(@as(u32, 1), fake.last_timeout_ms);
            try grt.std.testing.expect(!fake.last_tx_crc);
            try grt.std.testing.expect(!fake.last_rx_crc);
            try grt.std.testing.expect(fake.last_reset_collision);
            try grt.std.testing.expectEqualSlices(u8, &.{0x26}, fake.last_tx[0..1]);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x44, 0x00 }, &rx);
        }

        fn validatesExchangeAndPropagatesErrors() !void {
            const Fake = struct {
                fail: bool = false,

                fn transceive(self: *@This(), _: Exchange, _: []u8) Error!usize {
                    if (self.fail) return error.Timeout;
                    return 0;
                }
            };

            var fake = Fake{ .fail = true };
            const type_a = TypeA.init(&fake);
            var rx: [1]u8 = undefined;

            try grt.std.testing.expectError(error.Timeout, type_a.transceive(.{
                .tx = &.{0x00},
                .tx_bits = 8,
                .timeout_ms = 1,
            }, &rx));

            fake.fail = false;
            try grt.std.testing.expectError(error.InvalidArgument, type_a.transceive(.{
                .tx = &.{0x00},
                .tx_bits = 9,
                .timeout_ms = 1,
            }, &rx));

            try grt.std.testing.expectError(error.InvalidArgument, type_a.transceive(.{
                .tx = &.{0x00},
                .tx_bits = 8,
                .timeout_ms = 0,
            }, &rx));

            try grt.std.testing.expectError(error.InvalidArgument, type_a.transceive(.{
                .tx = &.{},
                .tx_bits = 0,
                .timeout_ms = 1,
            }, &rx));

            try grt.std.testing.expectError(error.InvalidArgument, type_a.transceive(.{
                .tx = &.{0x00},
                .tx_bits = 0,
                .timeout_ms = 1,
            }, &rx));

            try grt.std.testing.expectError(error.InvalidArgument, type_a.transceive(.{
                .tx = &.{0x00},
                .tx_bits = 8,
                .timeout_ms = max_timeout_ms + 1,
            }, &rx));
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

            TestCase.dispatchesTransceiveWithExchangeFlags() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.validatesExchangeAndPropagatesErrors() catch |err| {
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
