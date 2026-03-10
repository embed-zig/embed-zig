const std = @import("std");

const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const WsFrame = struct {
    opcode: u8,
    payload: []u8,
};

pub fn handshake(stream: std.net.Stream, request: []const u8) !void {
    const key = headerValue(request, "Sec-WebSocket-Key") orelse return error.MissingKey;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(ws_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);

    var accept_buf: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return error.FormatError;
    try stream.writeAll(hdr);
}

pub fn readFrame(stream: std.net.Stream, buf: []u8) !WsFrame {
    var h: [2]u8 = undefined;
    try readExact(stream, &h);

    const fin = (h[0] & 0x80) != 0;
    if (!fin) return error.FragmentedFrameUnsupported;

    const opcode = h[0] & 0x0f;
    const masked = (h[1] & 0x80) != 0;

    var payload_len: usize = h[1] & 0x7f;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = (@as(usize, ext[0]) << 8) | @as(usize, ext[1]);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        const len_u64 =
            (@as(u64, ext[0]) << 56) | (@as(u64, ext[1]) << 48) |
            (@as(u64, ext[2]) << 40) | (@as(u64, ext[3]) << 32) |
            (@as(u64, ext[4]) << 24) | (@as(u64, ext[5]) << 16) |
            (@as(u64, ext[6]) << 8) | @as(u64, ext[7]);
        if (len_u64 > buf.len) return error.FrameTooLarge;
        payload_len = @intCast(len_u64);
    }

    if (payload_len > buf.len) return error.FrameTooLarge;

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        try readExact(stream, &mask_key);
    }

    try readExact(stream, buf[0..payload_len]);

    if (masked) {
        for (buf[0..payload_len], 0..) |*byte, idx| {
            byte.* ^= mask_key[idx % 4];
        }
    }

    return .{ .opcode = opcode, .payload = buf[0..payload_len] };
}

pub fn sendText(stream: std.net.Stream, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var h_len: usize = 0;
    header[h_len] = 0x81;
    h_len += 1;

    if (payload.len <= 125) {
        header[h_len] = @intCast(payload.len);
        h_len += 1;
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[h_len] = 126;
        h_len += 1;
        const len16: u16 = @intCast(payload.len);
        header[h_len] = @intCast((len16 >> 8) & 0xff);
        header[h_len + 1] = @intCast(len16 & 0xff);
        h_len += 2;
    } else {
        return error.FrameTooLarge;
    }

    try stream.writeAll(header[0..h_len]);
    try stream.writeAll(payload);
}

pub fn sendClose(stream: std.net.Stream) void {
    const close = [_]u8{ 0x88, 0x00 };
    stream.writeAll(&close) catch {};
}

pub fn isUpgrade(request: []const u8) bool {
    const upgrade = headerValue(request, "Upgrade") orelse return false;
    return std.ascii.eqlIgnoreCase(upgrade, "websocket");
}

pub fn parsePath(request: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return null;
    const line = request[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return null;
    const rest = line[4..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return rest[0..end];
}

pub fn headerValue(request: []const u8, target: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..sep], " \t");
        if (!std.ascii.eqlIgnoreCase(key, target)) continue;
        return std.mem.trim(u8, line[sep + 1 ..], " \t");
    }
    return null;
}

fn readExact(stream: std.net.Stream, out: []u8) !void {
    var done: usize = 0;
    while (done < out.len) {
        const n = stream.read(out[done..]) catch |err| switch (err) {
            error.ConnectionResetByPeer, error.BrokenPipe => return error.ConnectionClosed,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        done += n;
    }
}

pub fn sendHttp(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-cache\r\n\r\n", .{ status, content_type, body.len }) catch return;
    stream.writeAll(hdr) catch return;
    stream.writeAll(body) catch return;
}
