const binding = @import("../../src/binding.zig");
const PageMod = @import("../../src/Page.zig");

pub const PacketSpec = struct {
    len: usize,
    granulepos: i64,
    bos: bool = false,
    eos: bool = false,
};

pub const packet_specs = [_]PacketSpec{
    .{ .len = 17, .granulepos = 17, .bos = true },
    .{ .len = 255, .granulepos = 272 },
    .{ .len = 256, .granulepos = 528 },
    .{ .len = 9000, .granulepos = 9528 },
    .{ .len = 63, .granulepos = 9591 },
    .{ .len = 1024, .granulepos = 10615 },
    .{ .len = 511, .granulepos = 11126 },
    .{ .len = 13, .granulepos = 11139 },
    .{ .len = 4096, .granulepos = 15235 },
    .{ .len = 1, .granulepos = 15236 },
    .{ .len = 777, .granulepos = 16013, .eos = true },
};

pub const max_payload_len = 9000;
pub const serial = 0x1234;

pub fn appendCPage(allocator: anytype, bytes: anytype, page: *const PageMod) !void {
    const header = byteSlice(page.header, @intCast(page.header_len));
    const body = byteSlice(page.body, @intCast(page.body_len));
    try bytes.appendSlice(allocator, header);
    try bytes.appendSlice(allocator, body);
}

pub fn fillPayload(buf: []u8, packet_idx: usize) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @intCast((packet_idx * 37 + i * 13 + (i / 7) * 11) % 251);
    }
}

pub fn byteSlice(ptr: anytype, len: usize) []const u8 {
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}
