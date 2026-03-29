const embed = @import("embed");
const testing_api = @import("testing");
const binding = @import("../src/binding.zig");
const PageMod = @import("../src/Page.zig");
const types_mod = @import("../src/types.zig");
const SyncMod = @import("../src/Sync.zig");
const StreamMod = @import("../src/Stream.zig");

const PacketCount = 18;
const PayloadLen = 320;

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runImpl(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type) !void {
    const ogg = struct {
        pub const Page = PageMod;
        pub const Packet = binding.Packet;
        pub const PageOutResult = types_mod.PageOutResult;
        pub const PacketOutResult = types_mod.PacketOutResult;
        pub const Sync = SyncMod;
        pub const Stream = StreamMod;
    };
    const testing = lib.testing;

    var sync = ogg.Sync.init();
    defer sync.deinit();

    var writer = try ogg.Stream.init(0x1234);
    defer writer.deinit();

    var reader = try ogg.Stream.init(0x1234);
    defer reader.deinit();

    var encoded = try lib.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer encoded.deinit(testing.allocator);

    for (0..PacketCount) |packet_idx| {
        var payload: [PayloadLen]u8 = undefined;
        fillPayload(&payload, packet_idx);

        var packet = ogg.Packet{
            .packet = payload[0..].ptr,
            .bytes = PayloadLen,
            .b_o_s = @intFromBool(packet_idx == 0),
            .e_o_s = @intFromBool(packet_idx + 1 == PacketCount),
            .granulepos = @intCast((packet_idx + 1) * PayloadLen),
            .packetno = @intCast(packet_idx),
        };
        try writer.packetIn(&packet);

        var page: ogg.Page = undefined;
        while (writer.pageOut(&page)) {
            try appendPage(testing.allocator, &encoded, &page);
        }
    }

    var final_page: ogg.Page = undefined;
    while (writer.flush(&final_page)) {
        try appendPage(testing.allocator, &encoded, &final_page);
    }

    try testing.expect(encoded.items.len > PayloadLen);

    var recovered_packets: usize = 0;
    var cursor: usize = 0;
    while (cursor < encoded.items.len) {
        const chunk_len = @min(encoded.items.len - cursor, 17 + (cursor % 23));
        const buf = try sync.buffer(chunk_len);
        @memcpy(buf, encoded.items[cursor .. cursor + chunk_len]);
        try sync.wrote(chunk_len);
        cursor += chunk_len;

        try drainPackets(lib, &sync, &reader, &recovered_packets);
    }

    try drainPackets(lib, &sync, &reader, &recovered_packets);
    try testing.expectEqual(PacketCount, recovered_packets);
}

fn appendPage(allocator: anytype, bytes: anytype, page: anytype) !void {
    const header = byteSlice(page.header, @intCast(page.header_len));
    const body = byteSlice(page.body, @intCast(page.body_len));
    try bytes.appendSlice(allocator, header);
    try bytes.appendSlice(allocator, body);
}

fn drainPackets(comptime lib: type, sync: anytype, reader: anytype, recovered_packets: *usize) !void {
    const ogg = struct {
        pub const Page = PageMod;
        pub const Packet = binding.Packet;
        pub const PageOutResult = types_mod.PageOutResult;
        pub const PacketOutResult = types_mod.PacketOutResult;
    };
    const testing = lib.testing;

    while (true) {
        var page: ogg.Page = undefined;
        switch (sync.pageOut(&page)) {
            .need_more_data => return,
            .sync_lost => return error.UnexpectedSyncLoss,
            .page_ready => {
                try reader.pageIn(&page);
                try testing.expectEqual(@as(c_int, 0x1234), page.serialNo());

                while (true) {
                    var packet: ogg.Packet = undefined;
                    switch (reader.packetOut(&packet)) {
                        .need_more_data => break,
                        .error_or_hole => return error.UnexpectedPacketHole,
                        .packet_ready => {
                            var expected: [PayloadLen]u8 = undefined;
                            fillPayload(&expected, recovered_packets.*);
                            try testing.expectEqual(@as(usize, PayloadLen), @as(usize, @intCast(packet.bytes)));
                            try testing.expectEqualSlices(u8, expected[0..], byteSlice(packet.packet, PayloadLen));
                            recovered_packets.* += 1;
                        },
                    }
                }
            },
        }
    }
}

fn fillPayload(buf: []u8, packet_idx: usize) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @intCast((packet_idx * 37 + i * 13 + (i / 7) * 11) % 251);
    }
}

fn byteSlice(ptr: anytype, len: usize) []const u8 {
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}
