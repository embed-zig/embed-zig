const embed = @import("embed");
const testing_api = @import("testing");
const binding = @import("../../src/binding.zig");
const PageMod = @import("../../src/Page.zig");
const SyncMod = @import("../../src/Sync.zig");
const StreamMod = @import("../../src/Stream.zig");
const common = @import("common.zig");

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
    const testing = lib.testing;

    var sync = SyncMod.init();
    defer sync.deinit();

    var writer = try StreamMod.init(common.serial);
    defer writer.deinit();

    var reader = try StreamMod.init(common.serial);
    defer reader.deinit();

    var encoded = try lib.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer encoded.deinit(testing.allocator);

    for (common.packet_specs, 0..) |spec, packet_idx| {
        var payload: [common.max_payload_len]u8 = undefined;
        common.fillPayload(payload[0..spec.len], packet_idx);

        var packet = binding.Packet{
            .packet = payload[0..spec.len].ptr,
            .bytes = @intCast(spec.len),
            .b_o_s = @intFromBool(spec.bos),
            .e_o_s = @intFromBool(spec.eos),
            .granulepos = spec.granulepos,
            .packetno = @intCast(packet_idx),
        };
        try writer.packetIn(&packet);

        var page: PageMod = undefined;
        while (writer.pageOut(&page)) {
            try common.appendCPage(testing.allocator, &encoded, &page);
        }
    }

    var final_page: PageMod = undefined;
    while (writer.flush(&final_page)) {
        try common.appendCPage(testing.allocator, &encoded, &final_page);
    }

    try testing.expect(encoded.items.len > common.max_payload_len);

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
    try testing.expectEqual(common.packet_specs.len, recovered_packets);
}

fn drainPackets(comptime lib: type, sync: *SyncMod, reader: *StreamMod, recovered_packets: *usize) !void {
    const testing = lib.testing;

    while (true) {
        var page: PageMod = undefined;
        switch (sync.pageOut(&page)) {
            .need_more_data => return,
            .sync_lost => return error.UnexpectedSyncLoss,
            .page_ready => {
                try reader.pageIn(&page);
                try testing.expectEqual(@as(c_int, common.serial), page.serialNo());

                while (true) {
                    var packet: binding.Packet = undefined;
                    switch (reader.packetOut(&packet)) {
                        .need_more_data => break,
                        .error_or_hole => return error.UnexpectedPacketHole,
                        .packet_ready => {
                            const spec = common.packet_specs[recovered_packets.*];
                            var expected: [common.max_payload_len]u8 = undefined;
                            common.fillPayload(expected[0..spec.len], recovered_packets.*);
                            try testing.expectEqual(spec.len, @as(usize, @intCast(packet.bytes)));
                            try testing.expectEqualSlices(u8, expected[0..spec.len], common.byteSlice(packet.packet, spec.len));
                            try testing.expectEqual(spec.bos, packet.b_o_s != 0);
                            try testing.expectEqual(spec.eos, packet.e_o_s != 0);
                            try testing.expectEqual(spec.granulepos, @as(i64, @intCast(packet.granulepos)));
                            try testing.expectEqual(@as(i64, @intCast(recovered_packets.*)), @as(i64, @intCast(packet.packetno)));
                            recovered_packets.* += 1;
                        },
                    }
                }
            },
        }
    }
}
