//! WebSocket Frame Codec — RFC 6455 Section 5
//!
//! Handles encoding and decoding of WebSocket frames including masking.
//! Zero-allocation: frame headers are parsed from caller-provided buffers.

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const FrameHeader = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    mask_key: [4]u8,
    header_size: usize,
};

pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,
};

pub const Error = error{
    TruncatedHeader,
    TruncatedPayload,
    InvalidControlFrameLength,
    ReservedOpcode,
};

const MIN_HEADER_SIZE = 2;

pub fn decodeHeader(buf: []const u8) Error!FrameHeader {
    if (buf.len < MIN_HEADER_SIZE)
        return error.TruncatedHeader;

    const b0 = buf[0];
    const b1 = buf[1];

    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
    const masked = (b1 & 0x80) != 0;
    var payload_len: u64 = b1 & 0x7F;
    var pos: usize = 2;

    if (payload_len == 126) {
        if (buf.len < pos + 2) return error.TruncatedHeader;
        payload_len = readU16Big(buf[pos..][0..2]);
        pos += 2;
    } else if (payload_len == 127) {
        if (buf.len < pos + 8) return error.TruncatedHeader;
        payload_len = readU64Big(buf[pos..][0..8]);
        pos += 8;
    }

    const op_int = @intFromEnum(opcode);
    if (op_int >= 0x8 and payload_len > 125)
        return error.InvalidControlFrameLength;

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (buf.len < pos + 4) return error.TruncatedHeader;
        @memcpy(&mask_key, buf[pos..][0..4]);
        pos += 4;
    }

    return .{
        .fin = fin,
        .opcode = opcode,
        .masked = masked,
        .payload_len = payload_len,
        .mask_key = mask_key,
        .header_size = pos,
    };
}

pub fn decode(buf: []const u8) Error!Frame {
    const header = try decodeHeader(buf);
    if (header.payload_len > buf.len) return error.TruncatedPayload;
    const payload_len: usize = @intCast(header.payload_len);
    const total = header.header_size + payload_len;
    if (buf.len < total) return error.TruncatedPayload;

    return .{
        .header = header,
        .payload = buf[header.header_size..total],
    };
}

pub fn encodeHeader(
    out: []u8,
    opcode: Opcode,
    payload_len: u64,
    fin: bool,
    mask_key: ?[4]u8,
) usize {
    var pos: usize = 0;

    var b0: u8 = @intFromEnum(opcode);
    if (fin) b0 |= 0x80;
    out[pos] = b0;
    pos += 1;

    var b1: u8 = 0;
    if (mask_key != null) b1 |= 0x80;

    if (payload_len < 126) {
        b1 |= @intCast(payload_len);
        out[pos] = b1;
        pos += 1;
    } else if (payload_len <= 0xFFFF) {
        b1 |= 126;
        out[pos] = b1;
        pos += 1;
        writeU16Big(out[pos..][0..2], @intCast(payload_len));
        pos += 2;
    } else {
        b1 |= 127;
        out[pos] = b1;
        pos += 1;
        writeU64Big(out[pos..][0..8], payload_len);
        pos += 8;
    }

    if (mask_key) |key| {
        @memcpy(out[pos..][0..4], &key);
        pos += 4;
    }

    return pos;
}

/// Maximum encoded header size: 1(flags) + 1(len) + 8(ext len) + 4(mask) = 14
pub const MAX_HEADER_SIZE = 14;

pub fn applyMask(data: []u8, mask_key: [4]u8) void {
    for (data, 0..) |*b, i| {
        b.* ^= mask_key[i % 4];
    }
}

pub fn applyMaskOffset(data: []u8, mask_key: [4]u8, offset: usize) void {
    for (data, 0..) |*b, i| {
        b.* ^= mask_key[(i + offset) % 4];
    }
}

fn readU16Big(b: *const [2]u8) u16 {
    return @as(u16, b[0]) << 8 | @as(u16, b[1]);
}

fn readU64Big(b: *const [8]u8) u64 {
    var result: u64 = 0;
    inline for (0..8) |i| {
        result |= @as(u64, b[i]) << @intCast((7 - i) * 8);
    }
    return result;
}

pub fn writeU16Big(b: *[2]u8, v: u16) void {
    b[0] = @intCast(v >> 8);
    b[1] = @intCast(v & 0xFF);
}

fn writeU64Big(b: *[8]u8, v: u64) void {
    inline for (0..8) |i| {
        b[i] = @intCast((v >> @intCast((7 - i) * 8)) & 0xFF);
    }
}

// ==========================================================================
// Tests
// ==========================================================================

const std = @import("std");

test "encode text frame" {
    var buf: [MAX_HEADER_SIZE + 5]u8 = undefined;
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    const hdr_len = encodeHeader(&buf, .text, 5, true, mask);

    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x85), buf[1]);
    try std.testing.expectEqualSlices(u8, &mask, buf[2..6]);
    try std.testing.expectEqual(@as(usize, 6), hdr_len);
}

test "encode binary frame" {
    var buf: [MAX_HEADER_SIZE]u8 = undefined;
    const mask = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    const hdr_len = encodeHeader(&buf, .binary, 10, true, mask);

    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x8A), buf[1]);
    try std.testing.expectEqual(@as(usize, 6), hdr_len);
}

test "encode 126-byte payload" {
    var buf: [MAX_HEADER_SIZE]u8 = undefined;
    const mask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const hdr_len = encodeHeader(&buf, .binary, 200, true, mask);

    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xFE), buf[1]);
    try std.testing.expectEqual(@as(u16, 200), readU16Big(buf[2..4]));
    try std.testing.expectEqual(@as(usize, 8), hdr_len);
}

test "encode 65536-byte payload" {
    var buf: [MAX_HEADER_SIZE]u8 = undefined;
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    const hdr_len = encodeHeader(&buf, .binary, 65536, true, mask);

    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[1]);
    try std.testing.expectEqual(@as(u64, 65536), readU64Big(buf[2..10]));
    try std.testing.expectEqual(@as(usize, 14), hdr_len);
}

test "decode server frame (no mask)" {
    var buf = [_]u8{
        0x81, // FIN + text
        0x05, // no mask, len=5
        'h',
        'e',
        'l',
        'l',
        'o',
    };
    const f = try decode(&buf);
    try std.testing.expect(f.header.fin);
    try std.testing.expectEqual(Opcode.text, f.header.opcode);
    try std.testing.expect(!f.header.masked);
    try std.testing.expectEqual(@as(u64, 5), f.header.payload_len);
    try std.testing.expectEqualSlices(u8, "hello", f.payload);
}

test "decode 2-byte extended length" {
    var buf: [4 + 200]u8 = undefined;
    buf[0] = 0x82;
    buf[1] = 126;
    writeU16Big(buf[2..4], 200);
    @memset(buf[4..], 0xAB);

    const f = try decode(&buf);
    try std.testing.expectEqual(@as(u64, 200), f.header.payload_len);
    try std.testing.expectEqual(@as(usize, 200), f.payload.len);
    try std.testing.expectEqual(@as(usize, 4), f.header.header_size);
}

test "decode 8-byte extended length" {
    const payload_len: u64 = 70000;
    var buf: [10 + 70000]u8 = undefined;
    buf[0] = 0x82;
    buf[1] = 127;
    writeU64Big(buf[2..10], payload_len);
    @memset(buf[10..], 0xCD);

    const f = try decode(&buf);
    try std.testing.expectEqual(payload_len, f.header.payload_len);
    try std.testing.expectEqual(@as(usize, 70000), f.payload.len);
    try std.testing.expectEqual(@as(usize, 10), f.header.header_size);
}

test "decode with mask" {
    var buf = [_]u8{
        0x81,
        0x85,
        0x37,
        0xfa,
        0x21,
        0x3d,
        0x7f,
        0x9f,
        0x4d,
        0x51,
        0x58,
    };
    const f = try decode(&buf);
    try std.testing.expect(f.header.masked);
    try std.testing.expectEqual([4]u8{ 0x37, 0xfa, 0x21, 0x3d }, f.header.mask_key);

    var payload: [5]u8 = undefined;
    @memcpy(&payload, f.payload);
    applyMask(&payload, f.header.mask_key);
    try std.testing.expectEqualSlices(u8, "Hello", &payload);
}

test "decode truncated header" {
    const buf = [_]u8{0x81};
    try std.testing.expectError(error.TruncatedHeader, decodeHeader(&buf));
}

test "decode truncated payload" {
    const buf = [_]u8{
        0x81,
        0x05,
        'h',
        'e',
    };
    try std.testing.expectError(error.TruncatedPayload, decode(&buf));
}

test "ping frame encode/decode" {
    var buf: [MAX_HEADER_SIZE + 5]u8 = undefined;
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    const payload = "hello";
    const hdr_len = encodeHeader(&buf, .ping, payload.len, true, mask);
    @memcpy(buf[hdr_len..][0..payload.len], payload);
    applyMask(buf[hdr_len..][0..payload.len], mask);

    const f = try decode(buf[0 .. hdr_len + payload.len]);
    try std.testing.expectEqual(Opcode.ping, f.header.opcode);
    try std.testing.expect(f.header.fin);

    var decoded_payload: [5]u8 = undefined;
    @memcpy(&decoded_payload, f.payload);
    applyMask(&decoded_payload, f.header.mask_key);
    try std.testing.expectEqualSlices(u8, payload, &decoded_payload);
}

test "close frame encode/decode" {
    var buf: [MAX_HEADER_SIZE + 2]u8 = undefined;
    const mask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };

    var close_payload = [2]u8{ 0x03, 0xE8 };
    applyMask(&close_payload, mask);

    const hdr_len = encodeHeader(&buf, .close, 2, true, mask);
    @memcpy(buf[hdr_len..][0..2], &close_payload);

    const f = try decode(buf[0 .. hdr_len + 2]);
    try std.testing.expectEqual(Opcode.close, f.header.opcode);
    try std.testing.expect(f.header.fin);
    try std.testing.expectEqual(@as(u64, 2), f.header.payload_len);

    var status_bytes: [2]u8 = undefined;
    @memcpy(&status_bytes, f.payload);
    applyMask(&status_bytes, f.header.mask_key);
    const status = readU16Big(&status_bytes);
    try std.testing.expectEqual(@as(u16, 1000), status);
}

test "masking roundtrip" {
    const original = "The quick brown fox jumps over the lazy dog";
    var data: [original.len]u8 = undefined;
    @memcpy(&data, original);

    const mask = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    applyMask(&data, mask);

    try std.testing.expect(!std.mem.eql(u8, &data, original));

    applyMask(&data, mask);
    try std.testing.expectEqualSlices(u8, original, &data);
}

test "encode unmasked server frame" {
    var buf: [MAX_HEADER_SIZE]u8 = undefined;
    const hdr_len = encodeHeader(&buf, .text, 5, true, null);

    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x05), buf[1]);
    try std.testing.expectEqual(@as(usize, 2), hdr_len);
}

test "applyMaskOffset matches applyMask at offset 0" {
    const original = "test data here!";
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };

    var a: [original.len]u8 = undefined;
    var b_buf: [original.len]u8 = undefined;
    @memcpy(&a, original);
    @memcpy(&b_buf, original);

    applyMask(&a, mask);
    applyMaskOffset(&b_buf, mask, 0);

    try std.testing.expectEqualSlices(u8, &a, &b_buf);
}

test "decode empty buffer" {
    const buf = [_]u8{};
    try std.testing.expectError(error.TruncatedHeader, decodeHeader(&buf));
}

test "non-fin text frame header" {
    var buf: [MAX_HEADER_SIZE]u8 = undefined;
    const hdr_len = encodeHeader(&buf, .text, 10, false, null);

    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
    try std.testing.expectEqual(@as(usize, 2), hdr_len);

    const header = try decodeHeader(buf[0..hdr_len]);
    try std.testing.expect(!header.fin);
    try std.testing.expectEqual(Opcode.text, header.opcode);
}
