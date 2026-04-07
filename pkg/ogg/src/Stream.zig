const binding = @import("binding.zig");
const Page = @import("Page.zig");
const PacketOutResult = @import("types.zig").PacketOutResult;
const testing_api = @import("testing");

const Self = @This();

state: binding.StreamState,

pub const InitError = error{
    StreamInitFailed,
};

pub const PageInError = error{
    PageInFailed,
};

pub const PacketInError = error{
    PacketInFailed,
};

pub fn init(serial: i32) InitError!Self {
    return initWith(binding.ogg_stream_init, serial);
}

fn initWith(init_fn: anytype, serial: i32) InitError!Self {
    var self = Self{ .state = undefined };
    if (init_fn(&self.state, serial) != 0) {
        return error.StreamInitFailed;
    }
    return self;
}

pub fn deinit(self: *Self) void {
    _ = binding.ogg_stream_clear(&self.state);
}

pub fn reset(self: *Self) void {
    _ = binding.ogg_stream_reset(&self.state);
}

pub fn resetSerial(self: *Self, serial: i32) void {
    _ = binding.ogg_stream_reset_serialno(&self.state, serial);
}

pub fn pageIn(self: *Self, page: *Page) PageInError!void {
    if (binding.ogg_stream_pagein(&self.state, @ptrCast(page)) != 0) {
        return error.PageInFailed;
    }
}

pub fn packetOut(self: *Self, packet: *binding.Packet) PacketOutResult {
    const ret = binding.ogg_stream_packetout(&self.state, packet);
    return switch (ret) {
        1 => .packet_ready,
        0 => .need_more_data,
        else => .error_or_hole,
    };
}

pub fn packetPeek(self: *Self, packet: *binding.Packet) PacketOutResult {
    const ret = binding.ogg_stream_packetpeek(&self.state, packet);
    return switch (ret) {
        1 => .packet_ready,
        0 => .need_more_data,
        else => .error_or_hole,
    };
}

pub fn packetIn(self: *Self, packet: *binding.Packet) PacketInError!void {
    if (binding.ogg_stream_packetin(&self.state, packet) != 0) {
        return error.PacketInFailed;
    }
}

pub fn pageOut(self: *Self, page: *Page) bool {
    return binding.ogg_stream_pageout(&self.state, @ptrCast(page)) != 0;
}

pub fn flush(self: *Self, page: *Page) bool {
    return binding.ogg_stream_flush(&self.state, @ptrCast(page)) != 0;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testStateLifecycle() !void {
            var stream = try Self.init(12345);
            defer stream.deinit();

            stream.reset();
            stream.resetSerial(67890);
        }

        fn testPacketOutReturnsNeedMoreDataOnEmptyStream() !void {
            const testing = lib.testing;

            var stream = try Self.init(1);
            defer stream.deinit();

            var packet: binding.Packet = undefined;
            const result = stream.packetOut(&packet);
            try testing.expectEqual(PacketOutResult.need_more_data, result);
        }

        fn testInitPropagatesInitFailure() !void {
            const testing = lib.testing;

            const FailingBinding = struct {
                fn ogg_stream_init(_: *binding.StreamState, _: i32) c_int {
                    return -1;
                }
            };

            try testing.expectError(
                InitError.StreamInitFailed,
                initWith(FailingBinding.ogg_stream_init, 12345),
            );
        }

        fn testPacketPeekReturnsNeedMoreDataOnEmptyStream() !void {
            const testing = lib.testing;

            var stream = try Self.init(1);
            defer stream.deinit();

            var packet: binding.Packet = undefined;
            const result = stream.packetPeek(&packet);
            try testing.expectEqual(PacketOutResult.need_more_data, result);
        }

        fn testPacketPeekDoesNotConsumePacket() !void {
            const testing = lib.testing;

            var writer = try Self.init(0x3456);
            defer writer.deinit();

            var reader = try Self.init(0x3456);
            defer reader.deinit();

            var payload = [_]u8{ 0x10, 0x20, 0x30 };
            var packet = binding.Packet{
                .packet = payload[0..].ptr,
                .bytes = payload.len,
                .b_o_s = 1,
                .e_o_s = 1,
                .granulepos = payload.len,
                .packetno = 0,
            };
            try writer.packetIn(&packet);

            var page: Page = undefined;
            try testing.expect(writer.flush(&page));
            try reader.pageIn(&page);

            var peeked: binding.Packet = undefined;
            try testing.expectEqual(PacketOutResult.packet_ready, reader.packetPeek(&peeked));
            try testing.expectEqual(@as(c_long, payload.len), peeked.bytes);
            try testing.expectEqualSlices(u8, payload[0..], @as([*]const u8, @ptrCast(peeked.packet))[0..payload.len]);

            var out: binding.Packet = undefined;
            try testing.expectEqual(PacketOutResult.packet_ready, reader.packetOut(&out));
            try testing.expectEqual(@as(c_long, payload.len), out.bytes);
            try testing.expectEqualSlices(u8, payload[0..], @as([*]const u8, @ptrCast(out.packet))[0..payload.len]);

            var none_left: binding.Packet = undefined;
            try testing.expectEqual(PacketOutResult.need_more_data, reader.packetOut(&none_left));
        }

        fn testPageInRejectsMismatchedSerialNumber() !void {
            const testing = lib.testing;

            var writer = try Self.init(1);
            defer writer.deinit();

            var reader = try Self.init(2);
            defer reader.deinit();

            var payload = [_]u8{ 0xAA };
            var packet = binding.Packet{
                .packet = payload[0..].ptr,
                .bytes = payload.len,
                .b_o_s = 1,
                .e_o_s = 1,
                .granulepos = 1,
                .packetno = 0,
            };
            try writer.packetIn(&packet);

            var page: Page = undefined;
            try testing.expect(writer.flush(&page));
            try testing.expectError(error.PageInFailed, reader.pageIn(&page));
        }

        fn testFlushExposesExpectedPageMetadata() !void {
            const testing = lib.testing;

            var stream = try Self.init(0x1234);
            defer stream.deinit();

            var payload = [_]u8{ 0xAB };
            var packet = binding.Packet{
                .packet = payload[0..].ptr,
                .bytes = payload.len,
                .b_o_s = 1,
                .e_o_s = 1,
                .granulepos = 1,
                .packetno = 0,
            };
            try stream.packetIn(&packet);

            var page: Page = undefined;
            try testing.expect(stream.flush(&page));
            try testing.expectEqual(@as(c_int, 0), page.version());
            try testing.expect(page.bos());
            try testing.expect(!page.continued());
            try testing.expect(page.eos());
            try testing.expectEqual(@as(c_int, 0x1234), page.serialNo());
            try testing.expectEqual(@as(c_long, 0), page.pageNo());
            try testing.expectEqual(@as(c_int, 1), page.packets());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testStateLifecycle() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPacketOutReturnsNeedMoreDataOnEmptyStream() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testInitPropagatesInitFailure() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPacketPeekReturnsNeedMoreDataOnEmptyStream() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPacketPeekDoesNotConsumePacket() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPageInRejectsMismatchedSerialNumber() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testFlushExposesExpectedPageMetadata() catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
