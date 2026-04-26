const glib = @import("glib");
const TypeA = @import("../io/TypeA.zig");

pub fn read(type_a: TypeA, addr: u8, out: []u8) TypeA.Error!void {
    if ((addr % 16) != 0) return error.InvalidArgument;
    if ((out.len % 16) != 0) return error.InvalidArgument;

    var page = addr / 4;
    var offset: usize = 0;
    while (offset < out.len) : ({
        offset += 16;
        page += 4;
    }) {
        try readOnce(type_a, page, out[offset .. offset + 16]);
    }
}

pub fn readAll(type_a: TypeA, buf: []u8) TypeA.Error!usize {
    if (buf.len < 16) return error.InvalidArgument;

    try read(type_a, 0, buf[0..16]);

    const total_len = 16 + @as(usize, buf[14]) * 8;
    if (buf.len < total_len) return error.InvalidArgument;
    if (total_len > 16) try read(type_a, 16, buf[16..total_len]);
    return total_len;
}

fn readOnce(type_a: TypeA, page: u8, out: []u8) TypeA.Error!void {
    if (out.len != 16) return error.InvalidArgument;

    var rx: [16]u8 = undefined;
    const bits = try type_a.transceive(.{
        .tx = &.{ 0x30, page },
        .tx_bits = 16,
        .timeout_ms = 5,
        .tx_crc = true,
        .rx_crc = true,
    }, &rx);

    if (bits != 16 * 8) return error.Protocol;
    @memcpy(out, &rx);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn readAllReadsCapacityDerivedLength() !void {
            const Fake = struct {
                step: usize = 0,

                pub fn transceive(self: *@This(), exchange: TypeA.Exchange, rx: []u8) TypeA.Error!usize {
                    defer self.step += 1;

                    switch (self.step) {
                        0 => {
                            if (exchange.tx.len != 2 or exchange.tx[0] != 0x30 or exchange.tx[1] != 0x00) return error.Unexpected;
                            if (!exchange.tx_crc or !exchange.rx_crc) return error.Unexpected;
                            var i: usize = 0;
                            while (i < 16) : (i += 1) rx[i] = @intCast(i);
                            rx[14] = 4;
                            return 16 * 8;
                        },
                        1 => {
                            if (exchange.tx.len != 2 or exchange.tx[0] != 0x30 or exchange.tx[1] != 0x04) return error.Unexpected;
                            var i: usize = 0;
                            while (i < 16) : (i += 1) rx[i] = @intCast(0xA0 + i);
                            return 16 * 8;
                        },
                        2 => {
                            if (exchange.tx.len != 2 or exchange.tx[0] != 0x30 or exchange.tx[1] != 0x08) return error.Unexpected;
                            var i: usize = 0;
                            while (i < 16) : (i += 1) rx[i] = @intCast(0xB0 + i);
                            return 16 * 8;
                        },
                        else => return error.Unexpected,
                    }
                }
            };

            var fake = Fake{};
            var buf: [64]u8 = undefined;
            const len = try readAll(TypeA.init(&fake), &buf);

            try grt.std.testing.expectEqual(@as(usize, 48), len);
            try grt.std.testing.expectEqual(@as(u8, 0x04), buf[14]);
            try grt.std.testing.expectEqual(@as(u8, 0xA0), buf[16]);
            try grt.std.testing.expectEqual(@as(u8, 0xAF), buf[31]);
            try grt.std.testing.expectEqual(@as(u8, 0xB0), buf[32]);
            try grt.std.testing.expectEqual(@as(u8, 0xBF), buf[47]);
        }

        fn readAllRejectsSmallOutputBuffer() !void {
            const Fake = struct {
                pub fn transceive(_: *@This(), _: TypeA.Exchange, rx: []u8) TypeA.Error!usize {
                    var i: usize = 0;
                    while (i < 16) : (i += 1) rx[i] = 0;
                    rx[14] = 8;
                    return 16 * 8;
                }
            };

            var fake = Fake{};
            var buf: [32]u8 = undefined;
            try grt.std.testing.expectError(error.InvalidArgument, readAll(TypeA.init(&fake), &buf));
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

            TestCase.readAllReadsCapacityDerivedLength() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.readAllRejectsSmallOutputBuffer() catch |err| {
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
