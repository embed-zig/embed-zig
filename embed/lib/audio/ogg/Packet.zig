//! `audio/ogg/Packet.zig` owns the pure Zig rewrite of upstream `ogg_packet`
//! plus the clear behavior needed by encode/decode paths.

const glib = @import("glib");

const Self = @This();

pub const Options = struct {
    bos: bool = false,
    eos: bool = false,
    granulepos: i64 = 0,
    packetno: i64 = 0,
};

allocator: ?glib.std.mem.Allocator = null,
packet: []const u8 = &.{},
bos: bool = false,
eos: bool = false,
granulepos: i64 = 0,
packetno: i64 = 0,
owns_packet: bool = false,

pub fn initBorrowed(packet: []const u8, options: Options) Self {
    return .{
        .packet = packet,
        .bos = options.bos,
        .eos = options.eos,
        .granulepos = options.granulepos,
        .packetno = options.packetno,
        .owns_packet = false,
    };
}

pub fn initOwned(
    allocator: glib.std.mem.Allocator,
    packet: []const u8,
    options: Options,
) glib.std.mem.Allocator.Error!Self {
    const owned_packet = try allocator.dupe(u8, packet);
    return .{
        .allocator = allocator,
        .packet = owned_packet,
        .bos = options.bos,
        .eos = options.eos,
        .granulepos = options.granulepos,
        .packetno = options.packetno,
        .owns_packet = true,
    };
}

pub fn payload(self: *const Self) []const u8 {
    return self.packet;
}

pub fn bytes(self: *const Self) usize {
    return self.packet.len;
}

pub fn clear(self: *Self) void {
    if (self.owns_packet) {
        if (self.allocator) |allocator| {
            allocator.free(self.packet);
        }
    }
    self.* = .{};
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn testBorrowedPacketExposesMetadataAndPayload() !void {
            const bytes_in = [_]u8{ 0x01, 0x02, 0x03 };
            const borrowed = initBorrowed(bytes_in[0..], .{
                .bos = true,
                .eos = false,
                .granulepos = 42,
                .packetno = 7,
            });

            try grt.std.testing.expectEqualSlices(u8, bytes_in[0..], borrowed.payload());
            try grt.std.testing.expectEqual(@as(usize, 3), borrowed.bytes());
            try grt.std.testing.expect(borrowed.bos);
            try grt.std.testing.expect(!borrowed.eos);
            try grt.std.testing.expectEqual(@as(i64, 42), borrowed.granulepos);
            try grt.std.testing.expectEqual(@as(i64, 7), borrowed.packetno);
        }

        fn testOwnedPacketCopiesInputBytes(allocator: glib.std.mem.Allocator) !void {
            var source = [_]u8{ 0xaa, 0xbb, 0xcc };
            var owned = try initOwned(allocator, source[0..], .{});
            defer owned.clear();

            source[0] = 0x11;
            try grt.std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc }, owned.payload());
            try grt.std.testing.expect(owned.owns_packet);
        }

        fn testClearResetsOwnedPacketState(allocator: glib.std.mem.Allocator) !void {
            var packet = try initOwned(allocator, &.{ 0xde, 0xad }, .{
                .bos = true,
                .eos = true,
                .granulepos = 9,
                .packetno = 10,
            });
            packet.clear();

            try grt.std.testing.expectEqual(@as(usize, 0), packet.bytes());
            try grt.std.testing.expectEqualSlices(u8, &.{}, packet.payload());
            try grt.std.testing.expect(!packet.bos);
            try grt.std.testing.expect(!packet.eos);
            try grt.std.testing.expectEqual(@as(i64, 0), packet.granulepos);
            try grt.std.testing.expectEqual(@as(i64, 0), packet.packetno);
            try grt.std.testing.expect(!packet.owns_packet);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.testBorrowedPacketExposesMetadataAndPayload() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testOwnedPacketCopiesInputBytes(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testClearResetsOwnedPacketState(allocator) catch |err| {
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
