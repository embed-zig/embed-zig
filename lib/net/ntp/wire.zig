const std = @import("std");
const types = @import("types.zig");

pub fn generateNonce(comptime lib: type) i64 {
    var buf: [8]u8 = undefined;
    lib.crypto.random.bytes(&buf);
    const raw = std.mem.readInt(i64, &buf, .little);
    return if (raw == 0) 1 else raw;
}

pub fn buildRequest(buf: *[48]u8, origin_time_ms: i64) void {
    @memset(buf, 0);
    buf[0] = 0b00_100_011;
    buf[1] = 0;
    buf[2] = 6;
    buf[3] = 0xEC;

    if (origin_time_ms != 0) {
        const ts = unixMsToNtp(origin_time_ms);
        writeTimestamp(buf[40..48], ts);
    }
}

pub fn parseResponse(buf: *const [48]u8, expected_origin: types.NtpTimestamp) types.QueryError!types.Response {
    const li = (buf[0] >> 6) & 0x03;
    if (li == 3) return error.InvalidResponse;

    const mode = buf[0] & 0x07;
    if (mode != 4 and mode != 5) return error.InvalidResponse;

    const origin = readTimestamp(buf[24..32]);
    const expected_secs_truncated: i64 = @as(i64, @as(u32, @truncate(@as(u64, @bitCast(expected_origin.seconds)))));
    if (origin.seconds != expected_secs_truncated or origin.fraction != expected_origin.fraction) {
        return error.OriginMismatch;
    }

    const stratum = buf[1];
    if (stratum == 0) return error.KissOfDeath;

    const receive_timestamp = readTimestamp(buf[32..40]);
    const transmit_timestamp = readTimestamp(buf[40..48]);
    return .{
        .receive_timestamp = receive_timestamp,
        .transmit_timestamp = transmit_timestamp,
        .receive_time_ms = ntpToUnixMs(receive_timestamp),
        .transmit_time_ms = ntpToUnixMs(transmit_timestamp),
        .stratum = stratum,
    };
}

pub fn readTimestamp(buf: *const [8]u8) types.NtpTimestamp {
    return .{
        .seconds = @as(i64, std.mem.readInt(u32, buf[0..4], .big)),
        .fraction = std.mem.readInt(u32, buf[4..8], .big),
    };
}

pub fn writeTimestamp(buf: *[8]u8, ts: types.NtpTimestamp) void {
    std.mem.writeInt(u32, buf[0..4], @truncate(@as(u64, @bitCast(ts.seconds))), .big);
    std.mem.writeInt(u32, buf[4..8], ts.fraction, .big);
}

pub fn ntpToUnixMs(ntp: types.NtpTimestamp) i64 {
    const unix_secs: i64 = ntp.seconds - types.NTP_UNIX_OFFSET;
    const ms: i64 = (@as(i64, ntp.fraction) * 1000) >> 32;
    return unix_secs * 1000 + ms;
}

pub fn unixMsToNtp(unix_ms: i64) types.NtpTimestamp {
    const unix_secs = @divFloor(unix_ms, 1000);
    const ms = @mod(unix_ms, 1000);
    return .{
        .seconds = unix_secs + types.NTP_UNIX_OFFSET,
        .fraction = @intCast((@as(u64, @intCast(ms)) << 32) / 1000),
    };
}

test "timestamp conversion round trip" {
    const test_ms: i64 = 1_706_000_000_000;
    const ntp = unixMsToNtp(test_ms);
    const back = ntpToUnixMs(ntp);
    try std.testing.expect(@abs(back - test_ms) <= 1);
}

test "request packet format" {
    var buf: [48]u8 = undefined;
    buildRequest(&buf, 0);

    try std.testing.expectEqual(@as(u8, 0x23), buf[0]);
    try std.testing.expectEqual(@as(u8, 6), buf[2]);
    for (buf[40..48]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "request packet writes transmit timestamp" {
    var buf: [48]u8 = undefined;
    buildRequest(&buf, 1_706_012_096_000);

    var saw_nonzero = false;
    for (buf[40..48]) |b| {
        if (b != 0) saw_nonzero = true;
    }
    try std.testing.expect(saw_nonzero);
}

test "parse response validates origin before stratum" {
    const origin_ms: i64 = 1_706_012_096_000;
    const origin = unixMsToNtp(origin_ms);
    const recv = unixMsToNtp(origin_ms + 12);
    const xmit = unixMsToNtp(origin_ms + 20);

    var buf: [48]u8 = [_]u8{0} ** 48;
    buf[0] = 0b00_100_100;
    buf[1] = 0;
    writeTimestamp(buf[24..32], origin);
    writeTimestamp(buf[32..40], recv);
    writeTimestamp(buf[40..48], xmit);

    try std.testing.expectError(error.KissOfDeath, parseResponse(&buf, origin));

    buf[1] = 2;
    var wrong_origin = origin;
    wrong_origin.fraction +%= 1;
    writeTimestamp(buf[24..32], wrong_origin);
    try std.testing.expectError(error.OriginMismatch, parseResponse(&buf, origin));
}

test "parse response returns timestamps" {
    const origin_ms: i64 = 1_706_012_096_000;
    const origin = unixMsToNtp(origin_ms);
    const recv = unixMsToNtp(origin_ms + 15);
    const xmit = unixMsToNtp(origin_ms + 30);

    var buf: [48]u8 = [_]u8{0} ** 48;
    buf[0] = 0b00_100_100;
    buf[1] = 3;
    writeTimestamp(buf[24..32], origin);
    writeTimestamp(buf[32..40], recv);
    writeTimestamp(buf[40..48], xmit);

    const resp = try parseResponse(&buf, origin);
    try std.testing.expectEqual(@as(u8, 3), resp.stratum);
    try std.testing.expect(@abs(resp.receive_time_ms - (origin_ms + 15)) <= 1);
    try std.testing.expect(@abs(resp.transmit_time_ms - (origin_ms + 30)) <= 1);
}
