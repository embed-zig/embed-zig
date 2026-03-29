const embed = @import("embed");
const binding = @import("binding.zig");
const Page = @import("Page.zig");
const PacketOutResult = @import("types.zig").PacketOutResult;

const Self = @This();

state: binding.StreamState,

pub fn init(serial: i32) Self {
    var self = Self{ .state = undefined };
    _ = binding.ogg_stream_init(&self.state, serial);
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

pub fn pageIn(self: *Self, page: *Page) !void {
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

pub fn packetIn(self: *Self, packet: *binding.Packet) !void {
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

test "ogg/unit_tests/Stream/state_lifecycle" {
    var stream = Self.init(12345);
    defer stream.deinit();

    stream.reset();
    stream.resetSerial(67890);
}

test "ogg/unit_tests/Stream/packetOut_returns_need_more_data_on_empty_stream" {
    const std = @import("std");
    const testing = std.testing;

    var stream = Self.init(1);
    defer stream.deinit();

    var packet: binding.Packet = undefined;
    const result = stream.packetOut(&packet);
    try testing.expectEqual(PacketOutResult.need_more_data, result);
}
