const stdz = @import("stdz");
const time_mod = @import("time");
const types = @import("types.zig");
const testing_api = @import("testing");

pub fn generateNonce(comptime std: type) i64 {
    var buf: [8]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const raw = std.mem.readInt(i64, &buf, .little);
    return if (raw == 0) 1 else raw;
}

pub fn buildRequest(buf: *[48]u8, origin_time: time_mod.Time) void {
    @memset(buf, 0);
    buf[0] = 0b00_100_011;
    buf[1] = 0;
    buf[2] = 6;
    buf[3] = 0xEC;

    if (!origin_time.isZero()) {
        const ts = timeToNtp(origin_time);
        writeTimestamp(buf[40..48], ts);
    }
}

pub fn parseResponse(buf: *const [48]u8, expected_origin: types.NtpTimestamp) types.QueryError!types.Response {
    const li = (buf[0] >> 6) & 0x03;
    if (li == 3) return error.InvalidResponse;

    const version = (buf[0] >> 3) & 0x07;
    if (version != 4) return error.InvalidResponse;

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
        .receive_time = ntpToTime(receive_timestamp),
        .transmit_time = ntpToTime(transmit_timestamp),
        .stratum = stratum,
    };
}

pub fn readTimestamp(buf: *const [8]u8) types.NtpTimestamp {
    return .{
        .seconds = @as(i64, stdz.mem.readInt(u32, buf[0..4], .big)),
        .fraction = stdz.mem.readInt(u32, buf[4..8], .big),
    };
}

pub fn writeTimestamp(buf: *[8]u8, ts: types.NtpTimestamp) void {
    stdz.mem.writeInt(u32, buf[0..4], @truncate(@as(u64, @bitCast(ts.seconds))), .big);
    stdz.mem.writeInt(u32, buf[4..8], ts.fraction, .big);
}

pub fn ntpToTime(ntp: types.NtpTimestamp) time_mod.Time {
    const unix_secs: i64 = ntp.seconds - types.NTP_UNIX_OFFSET;
    const nsec: i64 = @intCast((@as(u128, ntp.fraction) * @as(u128, @intCast(time_mod.duration.Second))) >> 32);
    return time_mod.unix(unix_secs, nsec);
}

pub fn timeToNtp(time: time_mod.Time) types.NtpTimestamp {
    return .{
        .seconds = time.sec + types.NTP_UNIX_OFFSET,
        .fraction = @intCast((@as(u128, time.nsec) << 32) / @as(u128, @intCast(time_mod.duration.Second))),
    };
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, _: std.mem.Allocator) !void {
            const testing = std.testing;

            const test_time = time_mod.fromUnixMilli(1_706_000_000_000);
            const ntp = timeToNtp(test_time);
            const back = ntpToTime(ntp);
            try testing.expect(@abs(back.sub(test_time)) <= time_mod.duration.MicroSecond);

            {
                var buf: [48]u8 = undefined;
                buildRequest(&buf, .{});

                try testing.expectEqual(@as(u8, 0x23), buf[0]);
                try testing.expectEqual(@as(u8, 6), buf[2]);
                for (buf[40..48]) |b| try testing.expectEqual(@as(u8, 0), b);
            }

            {
                var buf: [48]u8 = undefined;
                buildRequest(&buf, time_mod.fromUnixMilli(1_706_012_096_000));

                var saw_nonzero = false;
                for (buf[40..48]) |b| {
                    if (b != 0) saw_nonzero = true;
                }
                try testing.expect(saw_nonzero);
            }

            {
                const origin_time = time_mod.fromUnixMilli(1_706_012_096_000);
                const origin = timeToNtp(origin_time);
                const recv = timeToNtp(origin_time.add(12 * time_mod.duration.MilliSecond));
                const xmit = timeToNtp(origin_time.add(20 * time_mod.duration.MilliSecond));

                var buf: [48]u8 = [_]u8{0} ** 48;
                buf[0] = 0b00_100_100;
                buf[1] = 0;
                writeTimestamp(buf[24..32], origin);
                writeTimestamp(buf[32..40], recv);
                writeTimestamp(buf[40..48], xmit);

                try testing.expectError(error.KissOfDeath, parseResponse(&buf, origin));

                buf[1] = 2;
                var wrong_origin = origin;
                wrong_origin.fraction +%= 1;
                writeTimestamp(buf[24..32], wrong_origin);
                try testing.expectError(error.OriginMismatch, parseResponse(&buf, origin));
            }

            {
                const origin_time = time_mod.fromUnixMilli(1_706_012_096_000);
                const origin = timeToNtp(origin_time);
                const recv_time = origin_time.add(15 * time_mod.duration.MilliSecond);
                const xmit_time = origin_time.add(30 * time_mod.duration.MilliSecond);
                const recv = timeToNtp(recv_time);
                const xmit = timeToNtp(xmit_time);

                var buf: [48]u8 = [_]u8{0} ** 48;
                buf[0] = 0b00_100_100;
                buf[1] = 3;
                writeTimestamp(buf[24..32], origin);
                writeTimestamp(buf[32..40], recv);
                writeTimestamp(buf[40..48], xmit);

                const resp = try parseResponse(&buf, origin);
                try testing.expectEqual(@as(u8, 3), resp.stratum);
                try testing.expect(@abs(resp.receive_time.sub(recv_time)) <= time_mod.duration.MicroSecond);
                try testing.expect(@abs(resp.transmit_time.sub(xmit_time)) <= time_mod.duration.MicroSecond);
            }

            {
                const origin_time = time_mod.fromUnixMilli(1_706_012_096_000);
                const origin = timeToNtp(origin_time);
                const recv = timeToNtp(origin_time.add(15 * time_mod.duration.MilliSecond));
                const xmit = timeToNtp(origin_time.add(30 * time_mod.duration.MilliSecond));

                var buf: [48]u8 = [_]u8{0} ** 48;
                buf[0] = 0b00_011_100;
                buf[1] = 3;
                writeTimestamp(buf[24..32], origin);
                writeTimestamp(buf[32..40], recv);
                writeTimestamp(buf[40..48], xmit);

                try testing.expectError(error.InvalidResponse, parseResponse(&buf, origin));
            }
        }
    }.run);
}
