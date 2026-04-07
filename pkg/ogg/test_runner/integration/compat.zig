const embed = @import("embed");
const testing_api = @import("testing");
const binding = @import("../../src/binding.zig");
const PageMod = @import("../../src/Page.zig");
const SyncMod = @import("../../src/Sync.zig");
const StreamMod = @import("../../src/Stream.zig");
const pure_ogg = @import("audio").ogg;
const common = @import("common.zig");

const PageSpan = struct {
    start: usize,
    len: usize,
};

fn EncodedFixture(comptime lib: type) type {
    return struct {
        bytes: lib.ArrayList(u8),
        spans: lib.ArrayList(PageSpan),

        fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            self.bytes.deinit(allocator);
            self.spans.deinit(allocator);
        }
    };
}

pub fn make(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testValidSyntheticParity(allocator: embed.mem.Allocator) !void {
            const testing = lib.testing;

            var c_writer = try StreamMod.init(common.serial);
            defer c_writer.deinit();

            var pure_writer = try pure_ogg.Stream.init(testing.allocator, common.serial);
            defer pure_writer.deinit();

            var c_encoded = try lib.ArrayList(u8).initCapacity(testing.allocator, 0);
            defer c_encoded.deinit(testing.allocator);

            var pure_encoded = try lib.ArrayList(u8).initCapacity(testing.allocator, 0);
            defer pure_encoded.deinit(testing.allocator);

            for (common.packet_specs, 0..) |spec, packet_idx| {
                const payload = try allocator.alloc(u8, spec.len);
                defer allocator.free(payload);
                common.fillPayload(payload, packet_idx);

                var c_packet = binding.Packet{
                    .packet = payload.ptr,
                    .bytes = @intCast(spec.len),
                    .b_o_s = @intFromBool(spec.bos),
                    .e_o_s = @intFromBool(spec.eos),
                    .granulepos = spec.granulepos,
                    .packetno = @intCast(packet_idx),
                };
                var pure_packet = pure_ogg.Packet.initBorrowed(payload, .{
                    .bos = spec.bos,
                    .eos = spec.eos,
                    .granulepos = spec.granulepos,
                    .packetno = @intCast(packet_idx),
                });
                try c_writer.packetIn(&c_packet);
                try pure_writer.packetIn(&pure_packet);

                try drainEncodedPages(lib, &c_writer, &pure_writer, &c_encoded, &pure_encoded);
            }

            try flushEncodedPages(lib, &c_writer, &pure_writer, &c_encoded, &pure_encoded);
            try testing.expectEqualSlices(u8, c_encoded.items, pure_encoded.items);

            try compareDecodedParity(lib, common.packet_specs[0..], c_encoded.items);
        }

        fn testChecksumCorruptionRecoversParity(allocator: embed.mem.Allocator) !void {
            const specs = [_]common.PacketSpec{
                .{ .len = 64, .granulepos = 64, .bos = true },
                .{ .len = 65, .granulepos = 129 },
                .{ .len = 66, .granulepos = 195, .eos = true },
            };

            var fixture = try encodeFixture(lib, allocator, specs[0..], true);
            defer fixture.deinit(allocator);

            if (fixture.spans.items.len < 3) return error.ExpectedThreePages;
            fixture.bytes.items[fixture.spans.items[1].start + 22] ^= 0xff;

            var c_sync = SyncMod.init();
            defer c_sync.deinit();
            var pure_sync = pure_ogg.Sync.init(allocator);
            defer pure_sync.deinit();

            try feedAllBytes(lib, &c_sync, &pure_sync, fixture.bytes.items);

            var c_reader = try StreamMod.init(common.serial);
            defer c_reader.deinit();
            var pure_reader = try pure_ogg.Stream.init(allocator, common.serial);
            defer pure_reader.deinit();

            var pair = try nextPagePair(lib, &c_sync, &pure_sync);
            try c_reader.pageIn(&pair.c_page);
            try pure_reader.pageIn(&pair.pure_page);
            try expectPacketPeekAndOutMatchesSpec(lib, &c_reader, &pure_reader, 0, specs[0]);

            try expectSyncLossParity(lib, &c_sync, &pure_sync);

            pair = try nextPagePair(lib, &c_sync, &pure_sync);
            try c_reader.pageIn(&pair.c_page);
            try pure_reader.pageIn(&pair.pure_page);
            try expectPacketHoleParity(lib, &c_reader, &pure_reader);
            try expectPacketPeekAndOutMatchesSpec(lib, &c_reader, &pure_reader, 2, specs[2]);
            try expectNeedMorePageParity(lib, &c_sync, &pure_sync);
            try expectNoPacketReadyParity(lib, &c_reader, &pure_reader);
        }

        fn testMissingPageProducesHoleParity(allocator: embed.mem.Allocator) !void {
            const specs = [_]common.PacketSpec{
                .{ .len = 32, .granulepos = 32, .bos = true },
                .{ .len = 33, .granulepos = 65 },
                .{ .len = 34, .granulepos = 99, .eos = true },
            };

            var fixture = try encodeFixture(lib, allocator, specs[0..], true);
            defer fixture.deinit(allocator);

            if (fixture.spans.items.len < 3) return error.ExpectedThreePages;

            var c_sync = SyncMod.init();
            defer c_sync.deinit();
            var pure_sync = pure_ogg.Sync.init(allocator);
            defer pure_sync.deinit();

            const page0 = fixture.bytes.items[fixture.spans.items[0].start .. fixture.spans.items[0].start + fixture.spans.items[0].len];
            const page2 = fixture.bytes.items[fixture.spans.items[2].start .. fixture.spans.items[2].start + fixture.spans.items[2].len];
            try feedAllBytes(lib, &c_sync, &pure_sync, page0);
            try feedAllBytes(lib, &c_sync, &pure_sync, page2);

            var c_reader = try StreamMod.init(common.serial);
            defer c_reader.deinit();
            var pure_reader = try pure_ogg.Stream.init(allocator, common.serial);
            defer pure_reader.deinit();

            var pair = try nextPagePair(lib, &c_sync, &pure_sync);
            try c_reader.pageIn(&pair.c_page);
            try pure_reader.pageIn(&pair.pure_page);
            try expectPacketPeekAndOutMatchesSpec(lib, &c_reader, &pure_reader, 0, specs[0]);

            pair = try nextPagePair(lib, &c_sync, &pure_sync);
            try c_reader.pageIn(&pair.c_page);
            try pure_reader.pageIn(&pair.pure_page);
            try expectPacketHoleParity(lib, &c_reader, &pure_reader);
            try expectPacketPeekAndOutMatchesSpec(lib, &c_reader, &pure_reader, 2, specs[2]);
            try expectNeedMorePageParity(lib, &c_sync, &pure_sync);
            try expectNoPacketReadyParity(lib, &c_reader, &pure_reader);
        }

        fn testContinuedPacketBoundaryParity(allocator: embed.mem.Allocator) !void {
            const specs = [_]common.PacketSpec{
                .{ .len = 70_000, .granulepos = 70_000, .bos = true },
                .{ .len = 17, .granulepos = 70_017, .eos = true },
            };

            var c_writer = try StreamMod.init(common.serial);
            defer c_writer.deinit();
            var pure_writer = try pure_ogg.Stream.init(allocator, common.serial);
            defer pure_writer.deinit();

            var c_reader = try StreamMod.init(common.serial);
            defer c_reader.deinit();
            var pure_reader = try pure_ogg.Stream.init(allocator, common.serial);
            defer pure_reader.deinit();

            const large_payload = try allocator.alloc(u8, specs[0].len);
            defer allocator.free(large_payload);
            common.fillPayload(large_payload, 0);

            var c_large_packet = binding.Packet{
                .packet = large_payload.ptr,
                .bytes = @intCast(specs[0].len),
                .b_o_s = 1,
                .e_o_s = 0,
                .granulepos = specs[0].granulepos,
                .packetno = 0,
            };
            var pure_large_packet = pure_ogg.Packet.initBorrowed(large_payload, .{
                .bos = true,
                .eos = false,
                .granulepos = specs[0].granulepos,
                .packetno = 0,
            });
            try c_writer.packetIn(&c_large_packet);
            try pure_writer.packetIn(&pure_large_packet);

            try drainPagesIntoReaders(lib, &c_writer, &pure_writer, &c_reader, &pure_reader);
            try expectNoPacketReadyParity(lib, &c_reader, &pure_reader);

            const tail_payload = try allocator.alloc(u8, specs[1].len);
            defer allocator.free(tail_payload);
            common.fillPayload(tail_payload, 1);

            var c_tail_packet = binding.Packet{
                .packet = tail_payload.ptr,
                .bytes = @intCast(specs[1].len),
                .b_o_s = 0,
                .e_o_s = 1,
                .granulepos = specs[1].granulepos,
                .packetno = 1,
            };
            var pure_tail_packet = pure_ogg.Packet.initBorrowed(tail_payload, .{
                .bos = false,
                .eos = true,
                .granulepos = specs[1].granulepos,
                .packetno = 1,
            });
            try c_writer.packetIn(&c_tail_packet);
            try pure_writer.packetIn(&pure_tail_packet);

            try drainPagesIntoReaders(lib, &c_writer, &pure_writer, &c_reader, &pure_reader);
            try flushPagesIntoReaders(lib, &c_writer, &pure_writer, &c_reader, &pure_reader);
            try expectPacketPeekAndOutMatchesSpec(lib, &c_reader, &pure_reader, 0, specs[0]);
            try expectPacketPeekAndOutMatchesSpec(lib, &c_reader, &pure_reader, 1, specs[1]);
            try expectNoPacketReadyParity(lib, &c_reader, &pure_reader);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            TestCase.testValidSyntheticParity(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testChecksumCorruptionRecoversParity(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testMissingPageProducesHoleParity(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testContinuedPacketBoundaryParity(allocator) catch |err| {
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

fn appendTrackedPage(comptime lib: type, allocator: embed.mem.Allocator, fixture: *EncodedFixture(lib), page: *const PageMod) !void {
    const start = fixture.bytes.items.len;
    try common.appendCPage(allocator, &fixture.bytes, page);
    try fixture.spans.append(allocator, .{ .start = start, .len = fixture.bytes.items.len - start });
}

fn encodeFixture(
    comptime lib: type,
    allocator: embed.mem.Allocator,
    specs: []const common.PacketSpec,
    flush_after_each_packet: bool,
) !EncodedFixture(lib) {
    var writer = try StreamMod.init(common.serial);
    defer writer.deinit();

    var fixture = EncodedFixture(lib){
        .bytes = try lib.ArrayList(u8).initCapacity(allocator, 0),
        .spans = try lib.ArrayList(PageSpan).initCapacity(allocator, 0),
    };
    errdefer fixture.deinit(allocator);

    for (specs, 0..) |spec, packet_idx| {
        const payload = try allocator.alloc(u8, spec.len);
        defer allocator.free(payload);
        common.fillPayload(payload, packet_idx);

        var packet = binding.Packet{
            .packet = payload.ptr,
            .bytes = @intCast(spec.len),
            .b_o_s = @intFromBool(spec.bos),
            .e_o_s = @intFromBool(spec.eos),
            .granulepos = spec.granulepos,
            .packetno = @intCast(packet_idx),
        };
        try writer.packetIn(&packet);

        var page: PageMod = undefined;
        if (flush_after_each_packet) {
            while (writer.flush(&page)) {
                try appendTrackedPage(lib, allocator, &fixture, &page);
            }
        } else {
            while (writer.pageOut(&page)) {
                try appendTrackedPage(lib, allocator, &fixture, &page);
            }
        }
    }

    var final_page: PageMod = undefined;
    while (writer.flush(&final_page)) {
        try appendTrackedPage(lib, allocator, &fixture, &final_page);
    }
    return fixture;
}

fn drainEncodedPages(
    comptime lib: type,
    c_writer: *StreamMod,
    pure_writer: *pure_ogg.Stream,
    c_encoded: anytype,
    pure_encoded: anytype,
) !void {
    const testing = lib.testing;

    while (true) {
        var c_page: PageMod = undefined;
        const c_ready = c_writer.pageOut(&c_page);
        var pure_page = (try pure_writer.pageOut()) orelse {
            try testing.expect(!c_ready);
            return;
        };
        try testing.expect(c_ready);
        try expectPagesEqual(lib, &c_page, &pure_page);
        try common.appendCPage(testing.allocator, c_encoded, &c_page);
        try appendPurePage(testing.allocator, pure_encoded, &pure_page);
    }
}

fn drainPagesIntoReaders(
    comptime lib: type,
    c_writer: *StreamMod,
    pure_writer: *pure_ogg.Stream,
    c_reader: *StreamMod,
    pure_reader: *pure_ogg.Stream,
) !void {
    while (true) {
        const pair = (try nextEncodedPagePair(lib, c_writer, pure_writer)) orelse return;
        var page_pair = pair;
        try c_reader.pageIn(&page_pair.c_page);
        try pure_reader.pageIn(&page_pair.pure_page);
    }
}

fn flushEncodedPages(
    comptime lib: type,
    c_writer: *StreamMod,
    pure_writer: *pure_ogg.Stream,
    c_encoded: anytype,
    pure_encoded: anytype,
) !void {
    const testing = lib.testing;

    while (true) {
        var c_page: PageMod = undefined;
        const c_ready = c_writer.flush(&c_page);
        var pure_page = (try pure_writer.flush()) orelse {
            try testing.expect(!c_ready);
            return;
        };
        try testing.expect(c_ready);
        try expectPagesEqual(lib, &c_page, &pure_page);
        try common.appendCPage(testing.allocator, c_encoded, &c_page);
        try appendPurePage(testing.allocator, pure_encoded, &pure_page);
    }
}

fn flushPagesIntoReaders(
    comptime lib: type,
    c_writer: *StreamMod,
    pure_writer: *pure_ogg.Stream,
    c_reader: *StreamMod,
    pure_reader: *pure_ogg.Stream,
) !void {
    while (true) {
        const pair = (try nextFlushedPagePair(lib, c_writer, pure_writer)) orelse return;
        var page_pair = pair;
        try c_reader.pageIn(&page_pair.c_page);
        try pure_reader.pageIn(&page_pair.pure_page);
    }
}

fn compareDecodedParity(comptime lib: type, specs: []const common.PacketSpec, encoded: []const u8) !void {
    const testing = lib.testing;

    var c_sync = SyncMod.init();
    defer c_sync.deinit();

    var c_reader = try StreamMod.init(common.serial);
    defer c_reader.deinit();

    var pure_sync = pure_ogg.Sync.init(testing.allocator);
    defer pure_sync.deinit();

    var pure_reader = try pure_ogg.Stream.init(testing.allocator, common.serial);
    defer pure_reader.deinit();

    var recovered_packets: usize = 0;
    var cursor: usize = 0;
    while (cursor < encoded.len) {
        const chunk_len = @min(encoded.len - cursor, 31 + (cursor % 97));

        const c_buf = try c_sync.buffer(chunk_len);
        @memcpy(c_buf, encoded[cursor .. cursor + chunk_len]);
        try c_sync.wrote(chunk_len);

        const pure_buf = try pure_sync.buffer(chunk_len);
        @memcpy(pure_buf, encoded[cursor .. cursor + chunk_len]);
        try pure_sync.wrote(chunk_len);

        cursor += chunk_len;
        try drainDecodedPages(lib, specs, &c_sync, &c_reader, &pure_sync, &pure_reader, &recovered_packets);
    }

    try drainDecodedPages(lib, specs, &c_sync, &c_reader, &pure_sync, &pure_reader, &recovered_packets);
    try testing.expectEqual(specs.len, recovered_packets);
}

fn drainDecodedPages(
    comptime lib: type,
    specs: []const common.PacketSpec,
    c_sync: *SyncMod,
    c_reader: *StreamMod,
    pure_sync: *pure_ogg.Sync,
    pure_reader: *pure_ogg.Stream,
    recovered_packets: *usize,
) !void {
    while (true) {
        var c_page: PageMod = undefined;
        switch (c_sync.pageOut(&c_page)) {
            .need_more_data => {
                switch (try pure_sync.pageOut()) {
                    .need_more => return,
                    else => return error.PageOutParityMismatch,
                }
            },
            .sync_lost => return error.UnexpectedSyncLoss,
            .page_ready => {
                var pure_page = switch (try pure_sync.pageOut()) {
                    .page => |page| page,
                    else => return error.PageOutParityMismatch,
                };
                try expectPagesEqual(lib, &c_page, &pure_page);
                try c_reader.pageIn(&c_page);
                try pure_reader.pageIn(&pure_page);
                try drainDecodedPackets(lib, specs, c_reader, pure_reader, recovered_packets);
            },
        }
    }
}

fn drainDecodedPackets(
    comptime lib: type,
    specs: []const common.PacketSpec,
    c_reader: *StreamMod,
    pure_reader: *pure_ogg.Stream,
    recovered_packets: *usize,
) !void {
    while (true) {
        var c_peek: binding.Packet = undefined;
        switch (c_reader.packetPeek(&c_peek)) {
            .need_more_data => {
                switch (try pure_reader.packetPeek()) {
                    .none => return,
                    else => return error.PacketPeekParityMismatch,
                }
            },
            .error_or_hole => return error.UnexpectedPacketHole,
            .packet_ready => {
                const pure_peek = switch (try pure_reader.packetPeek()) {
                    .packet => |packet| packet,
                    else => return error.PacketPeekParityMismatch,
                };
                try expectPacketMatchesSpec(lib, &c_peek, pure_peek, recovered_packets.*, specs[recovered_packets.*]);
            },
        }

        var c_packet: binding.Packet = undefined;
        switch (c_reader.packetOut(&c_packet)) {
            .need_more_data => return error.PacketOutParityMismatch,
            .error_or_hole => return error.UnexpectedPacketHole,
            .packet_ready => {
                const pure_packet = switch (try pure_reader.packetOut()) {
                    .packet => |packet| packet,
                    else => return error.PacketOutParityMismatch,
                };
                try expectPacketMatchesSpec(lib, &c_packet, pure_packet, recovered_packets.*, specs[recovered_packets.*]);
                recovered_packets.* += 1;
            },
        }
    }
}

const PagePair = struct {
    c_page: PageMod,
    pure_page: pure_ogg.Page,
};

fn nextEncodedPagePair(comptime lib: type, c_writer: *StreamMod, pure_writer: *pure_ogg.Stream) !?PagePair {
    const testing = lib.testing;
    var c_page: PageMod = undefined;
    const c_ready = c_writer.pageOut(&c_page);
    var pure_page = (try pure_writer.pageOut()) orelse {
        try testing.expect(!c_ready);
        return null;
    };
    try testing.expect(c_ready);
    try expectPagesEqual(lib, &c_page, &pure_page);
    return .{ .c_page = c_page, .pure_page = pure_page };
}

fn nextFlushedPagePair(comptime lib: type, c_writer: *StreamMod, pure_writer: *pure_ogg.Stream) !?PagePair {
    const testing = lib.testing;
    var c_page: PageMod = undefined;
    const c_ready = c_writer.flush(&c_page);
    var pure_page = (try pure_writer.flush()) orelse {
        try testing.expect(!c_ready);
        return null;
    };
    try testing.expect(c_ready);
    try expectPagesEqual(lib, &c_page, &pure_page);
    return .{ .c_page = c_page, .pure_page = pure_page };
}

fn nextPagePair(comptime lib: type, c_sync: *SyncMod, pure_sync: *pure_ogg.Sync) !PagePair {
    var c_page: PageMod = undefined;
    switch (c_sync.pageOut(&c_page)) {
        .page_ready => {},
        .need_more_data => return error.PageOutParityMismatch,
        .sync_lost => return error.UnexpectedSyncLoss,
    }
    var pure_page = switch (try pure_sync.pageOut()) {
        .page => |page| page,
        else => return error.PageOutParityMismatch,
    };
    try expectPagesEqual(lib, &c_page, &pure_page);
    return .{ .c_page = c_page, .pure_page = pure_page };
}

fn expectNeedMorePageParity(comptime lib: type, c_sync: *SyncMod, pure_sync: *pure_ogg.Sync) !void {
    _ = lib;
    var c_page: PageMod = undefined;
    switch (c_sync.pageOut(&c_page)) {
        .need_more_data => {},
        else => return error.PageOutParityMismatch,
    }
    switch (try pure_sync.pageOut()) {
        .need_more => {},
        else => return error.PageOutParityMismatch,
    }
}

fn expectSyncLossParity(comptime lib: type, c_sync: *SyncMod, pure_sync: *pure_ogg.Sync) !void {
    _ = lib;
    var c_page: PageMod = undefined;
    switch (c_sync.pageOut(&c_page)) {
        .sync_lost => {},
        else => return error.PageOutParityMismatch,
    }
    switch (try pure_sync.pageOut()) {
        .hole => {},
        else => return error.PageOutParityMismatch,
    }
}

fn expectNoPacketReadyParity(comptime lib: type, c_reader: *StreamMod, pure_reader: *pure_ogg.Stream) !void {
    _ = lib;
    var c_peek: binding.Packet = undefined;
    switch (c_reader.packetPeek(&c_peek)) {
        .need_more_data => {},
        else => return error.PacketPeekParityMismatch,
    }
    switch (try pure_reader.packetPeek()) {
        .none => {},
        else => return error.PacketPeekParityMismatch,
    }

    var c_packet: binding.Packet = undefined;
    switch (c_reader.packetOut(&c_packet)) {
        .need_more_data => {},
        else => return error.PacketOutParityMismatch,
    }
    switch (try pure_reader.packetOut()) {
        .none => {},
        else => return error.PacketOutParityMismatch,
    }
}

fn expectPacketHoleParity(comptime lib: type, c_reader: *StreamMod, pure_reader: *pure_ogg.Stream) !void {
    _ = lib;
    var c_packet: binding.Packet = undefined;
    switch (c_reader.packetOut(&c_packet)) {
        .error_or_hole => {},
        else => return error.PacketOutParityMismatch,
    }
    switch (try pure_reader.packetOut()) {
        .hole => {},
        else => return error.PacketOutParityMismatch,
    }
}

fn expectPacketPeekAndOutMatchesSpec(
    comptime lib: type,
    c_reader: *StreamMod,
    pure_reader: *pure_ogg.Stream,
    packet_idx: usize,
    spec: common.PacketSpec,
) !void {
    var c_peek: binding.Packet = undefined;
    switch (c_reader.packetPeek(&c_peek)) {
        .packet_ready => {},
        else => return error.PacketPeekParityMismatch,
    }
    const pure_peek = switch (try pure_reader.packetPeek()) {
        .packet => |packet| packet,
        else => return error.PacketPeekParityMismatch,
    };
    try expectPacketMatchesSpec(lib, &c_peek, pure_peek, packet_idx, spec);

    var c_packet: binding.Packet = undefined;
    switch (c_reader.packetOut(&c_packet)) {
        .packet_ready => {},
        else => return error.PacketOutParityMismatch,
    }
    const pure_packet = switch (try pure_reader.packetOut()) {
        .packet => |packet| packet,
        else => return error.PacketOutParityMismatch,
    };
    try expectPacketMatchesSpec(lib, &c_packet, pure_packet, packet_idx, spec);
}

fn feedAllBytes(comptime lib: type, c_sync: *SyncMod, pure_sync: *pure_ogg.Sync, bytes: []const u8) !void {
    _ = lib;
    const c_buf = try c_sync.buffer(bytes.len);
    @memcpy(c_buf, bytes);
    try c_sync.wrote(bytes.len);

    const pure_buf = try pure_sync.buffer(bytes.len);
    @memcpy(pure_buf, bytes);
    try pure_sync.wrote(bytes.len);
}

fn appendPurePage(allocator: anytype, bytes: anytype, page: *const pure_ogg.Page) !void {
    try bytes.appendSlice(allocator, page.header);
    try bytes.appendSlice(allocator, page.body);
}

fn expectPagesEqual(comptime lib: type, c_page: *const PageMod, pure_page: *const pure_ogg.Page) !void {
    const testing = lib.testing;
    const c_header = common.byteSlice(c_page.header, @intCast(c_page.header_len));
    const c_body = common.byteSlice(c_page.body, @intCast(c_page.body_len));

    try testing.expectEqualSlices(u8, c_header, pure_page.header);
    try testing.expectEqualSlices(u8, c_body, pure_page.body);
    try testing.expectEqual(c_page.continued(), try pure_page.continued());
    try testing.expectEqual(c_page.bos(), try pure_page.bos());
    try testing.expectEqual(c_page.eos(), try pure_page.eos());
    try testing.expectEqual(@as(u8, @intCast(c_page.version())), try pure_page.version());
    try testing.expectEqual(@as(i64, @intCast(c_page.granulePos())), try pure_page.granulePos());
    try testing.expectEqual(@as(u32, @intCast(c_page.serialNo())), try pure_page.serialNo());
    try testing.expectEqual(@as(u32, @intCast(c_page.pageNo())), try pure_page.pageNo());
    try testing.expectEqual(@as(usize, @intCast(c_page.packets())), try pure_page.packetCount());
}

fn expectPacketMatchesSpec(
    comptime lib: type,
    c_packet: *const binding.Packet,
    pure_packet: pure_ogg.Packet,
    packet_idx: usize,
    spec: common.PacketSpec,
) !void {
    const testing = lib.testing;
    const expected = try testing.allocator.alloc(u8, spec.len);
    defer testing.allocator.free(expected);

    common.fillPayload(expected, packet_idx);

    try testing.expectEqual(spec.len, @as(usize, @intCast(c_packet.bytes)));
    try testing.expectEqualSlices(u8, expected, common.byteSlice(c_packet.packet, spec.len));
    try testing.expectEqualSlices(u8, expected, pure_packet.payload());
    try testing.expectEqual(c_packet.b_o_s != 0, pure_packet.bos);
    try testing.expectEqual(c_packet.e_o_s != 0, pure_packet.eos);
    try testing.expectEqual(@as(i64, @intCast(c_packet.granulepos)), pure_packet.granulepos);
    try testing.expectEqual(@as(i64, @intCast(c_packet.packetno)), pure_packet.packetno);
}
