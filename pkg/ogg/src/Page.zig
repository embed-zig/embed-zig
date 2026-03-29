const binding = @import("binding.zig");

const Self = @This();

header: [*c]u8,
header_len: c_long,
body: [*c]u8,
body_len: c_long,

pub fn version(self: *const Self) c_int {
    return binding.ogg_page_version(@ptrCast(self));
}

pub fn continued(self: *const Self) bool {
    return binding.ogg_page_continued(@ptrCast(self)) != 0;
}

pub fn bos(self: *const Self) bool {
    return binding.ogg_page_bos(@ptrCast(self)) != 0;
}

pub fn eos(self: *const Self) bool {
    return binding.ogg_page_eos(@ptrCast(self)) != 0;
}

pub fn granulePos(self: *const Self) i64 {
    return binding.ogg_page_granulepos(@ptrCast(self));
}

pub fn serialNo(self: *const Self) c_int {
    return binding.ogg_page_serialno(@ptrCast(self));
}

pub fn pageNo(self: *const Self) c_long {
    return binding.ogg_page_pageno(@ptrCast(self));
}

pub fn packets(self: *const Self) c_int {
    return binding.ogg_page_packets(@ptrCast(self));
}

test "ogg/unit_tests/Page/layout_matches_raw_ogg_page" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectEqual(@sizeOf(binding.Page), @sizeOf(Self));
    try testing.expectEqual(@alignOf(binding.Page), @alignOf(Self));

    _ = Self.version;
    _ = Self.serialNo;
    _ = Self.pageNo;
    _ = Self.packets;
}
