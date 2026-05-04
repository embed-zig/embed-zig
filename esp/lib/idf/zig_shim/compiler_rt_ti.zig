const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

// Minimal compiler-rt style shims for 128-bit integer division/modulo builtins
// that are missing from the current Xtensa ESP toolchain link environment.

const Log2Int = std.math.Log2Int;

const lo = switch (builtin.cpu.arch.endian()) {
    .big => 1,
    .little => 0,
};
const hi = 1 - lo;

fn divwideGeneric(_u1: u64, _u0: u64, v_: u64, r: *u64) u64 {
    @setRuntimeSafety(false);

    var v = v_;
    const b: u64 = 1 << 32;
    var un64: u64 = undefined;
    var un10: u64 = undefined;

    const s: Log2Int(u64) = @intCast(@clz(v));
    if (s > 0) {
        v <<= s;
        un64 = (_u1 << s) | (_u0 >> @intCast(64 - @as(u64, @intCast(s))));
        un10 = _u0 << s;
    } else {
        un64 = _u1;
        un10 = _u0;
    }

    const vn1 = v >> 32;
    const vn0 = v & std.math.maxInt(u32);

    const un1 = un10 >> 32;
    const un0 = un10 & std.math.maxInt(u32);

    var q1 = un64 / vn1;
    var rhat = un64 -% q1 *% vn1;

    while (q1 >= b or q1 * vn0 > b * rhat + un1) {
        q1 -= 1;
        rhat += vn1;
        if (rhat >= b) break;
    }

    const un21 = un64 *% b +% un1 -% q1 *% v;

    var q0 = un21 / vn1;
    rhat = un21 -% q0 *% vn1;

    while (q0 >= b or q0 * vn0 > b * rhat + un0) {
        q0 -= 1;
        rhat += vn1;
        if (rhat >= b) break;
    }

    r.* = (un21 *% b +% un0 -% q0 *% v) >> s;
    return q1 *% b +% q0;
}

fn udivmod(a_: u128, b_: u128, maybe_rem: ?*u128) u128 {
    @setRuntimeSafety(false);

    if (b_ > a_) {
        if (maybe_rem) |rem| rem.* = a_;
        return 0;
    }

    const a: [2]u64 = @bitCast(a_);
    const b: [2]u64 = @bitCast(b_);
    var q: [2]u64 = undefined;
    var r: [2]u64 = undefined;

    if (b[hi] == 0) {
        r[hi] = 0;
        if (a[hi] < b[lo]) {
            q[hi] = 0;
            q[lo] = divwideGeneric(a[hi], a[lo], b[lo], &r[lo]);
        } else {
            q[hi] = a[hi] / b[lo];
            q[lo] = divwideGeneric(a[hi] % b[lo], a[lo], b[lo], &r[lo]);
        }

        if (maybe_rem) |rem| rem.* = @bitCast(r);
        return @bitCast(q);
    }

    const shift: Log2Int(u128) = @intCast(@clz(b[hi]) - @clz(a[hi]));
    var af: u128 = @bitCast(a);
    var bf = @as(u128, @bitCast(b)) << shift;
    q = @bitCast(@as(u128, 0));

    for (0..shift + 1) |_| {
        q[lo] <<= 1;
        const s = @as(i128, @bitCast(bf -% af -% 1)) >> 127;
        q[lo] |= @intCast(s & 1);
        af -= bf & @as(u128, @bitCast(s));
        bf >>= 1;
    }

    if (maybe_rem) |rem| rem.* = @bitCast(af);
    return @bitCast(q);
}

export fn __udivti3(a: u128, b: u128) callconv(.c) u128 {
    return udivmod(a, b, null);
}

export fn __umodti3(a: u128, b: u128) callconv(.c) u128 {
    var r: u128 = undefined;
    _ = udivmod(a, b, &r);
    return r;
}

export fn __divti3(a: i128, b: i128) callconv(.c) i128 {
    @setRuntimeSafety(false);

    const s_a = a >> 127;
    const s_b = b >> 127;
    const an = (a ^ s_a) -% s_a;
    const bn = (b ^ s_b) -% s_b;
    const r = udivmod(@bitCast(an), @bitCast(bn), null);
    const s = s_a ^ s_b;
    return (@as(i128, @bitCast(r)) ^ s) -% s;
}

export fn __modti3(a: i128, b: i128) callconv(.c) i128 {
    @setRuntimeSafety(false);

    const s_a = a >> 127;
    const s_b = b >> 127;
    const an = (a ^ s_a) -% s_a;
    const bn = (b ^ s_b) -% s_b;
    var r: u128 = undefined;
    _ = udivmod(@bitCast(an), @bitCast(bn), &r);
    return (@as(i128, @bitCast(r)) ^ s_a) -% s_a;
}

fn abs128Bits(x: i128) u128 {
    const sign = x >> 127;
    return @bitCast((x ^ sign) -% sign);
}

fn expectDivwideCase(n_hi: u64, n_lo: u64, v: u64) !void {
    try testing.expect(v != 0);
    try testing.expect(n_hi < v);

    var rem: u64 = undefined;
    const q = divwideGeneric(n_hi, n_lo, v, &rem);
    const numerator = (@as(u128, n_hi) << 64) | @as(u128, n_lo);
    const expected_q = @divTrunc(numerator, @as(u128, v));
    const expected_r = @rem(numerator, @as(u128, v));

    try testing.expectEqual(@as(u64, @intCast(expected_q)), q);
    try testing.expectEqual(@as(u64, @intCast(expected_r)), rem);
    try testing.expect(rem < v);
    try testing.expectEqual(numerator, @as(u128, q) * @as(u128, v) + @as(u128, rem));
}

fn expectUnsignedCase(a: u128, b: u128) !void {
    try testing.expect(b != 0);

    var rem: u128 = undefined;
    const q = udivmod(a, b, &rem);
    const expected_q = @divTrunc(a, b);
    const expected_r = @rem(a, b);

    try testing.expectEqual(expected_q, q);
    try testing.expectEqual(expected_r, rem);
    try testing.expectEqual(expected_q, __udivti3(a, b));
    try testing.expectEqual(expected_r, __umodti3(a, b));
    try testing.expect(rem < b);
    try testing.expectEqual(a, q * b + rem);
}

fn expectSignedCase(a: i128, b: i128) !void {
    try testing.expect(b != 0);
    try testing.expect(!(a == std.math.minInt(i128) and b == -1));

    const expected_q = @divTrunc(a, b);
    const expected_r = @rem(a, b);
    const q = __divti3(a, b);
    const r = __modti3(a, b);

    try testing.expectEqual(expected_q, q);
    try testing.expectEqual(expected_r, r);
    try testing.expectEqual(a, q * b + r);
    try testing.expect(abs128Bits(r) < abs128Bits(b));

    if (r != 0) {
        try testing.expect((r > 0) == (a > 0));
    }
}

test "compiler_rt_ti divwideGeneric edge cases" {
    const max_u64 = std.math.maxInt(u64);

    const cases = [_]struct { u1: u64, u0: u64, v: u64 }{
        .{ .u1 = 0, .u0 = 0, .v = 1 },
        .{ .u1 = 0, .u0 = 1, .v = 1 },
        .{ .u1 = 0, .u0 = max_u64, .v = 2 },
        .{ .u1 = 1, .u0 = 0, .v = max_u64 },
        .{ .u1 = max_u64 - 1, .u0 = max_u64, .v = max_u64 },
        .{ .u1 = (1 << 63) - 1, .u0 = max_u64, .v = 1 << 63 },
        .{ .u1 = (1 << 63) - 2, .u0 = max_u64 - 1, .v = (1 << 63) + 1 },
        .{ .u1 = 0x1234_5678, .u0 = 0x9abc_def0_1234_5678, .v = 0x1_0000_0001 },
        .{ .u1 = 0x7fff_ffff_ffff_fffe, .u0 = 0xffff_ffff_ffff_fffd, .v = 0x8000_0000_0000_0001 },
    };

    for (cases) |case| {
        try expectDivwideCase(case.u1, case.u0, case.v);
    }

    var prng = std.Random.DefaultPrng.init(0x6d6f_6475_6c6f_31);
    const random = prng.random();
    for (0..512) |_| {
        var v = random.int(u64);
        if (v == 0) v = 1;

        var n_hi = random.int(u64);
        if (n_hi >= v) n_hi %= v;

        try expectDivwideCase(n_hi, random.int(u64), v);
    }
}

test "compiler_rt_ti unsigned division edge cases" {
    const max_u32 = std.math.maxInt(u32);
    const max_u64 = std.math.maxInt(u64);
    const max_u128 = std.math.maxInt(u128);

    const numerators = [_]u128{
        0,
        1,
        2,
        3,
        max_u32,
        @as(u128, max_u32) + 1,
        @as(u128, max_u64) - 1,
        max_u64,
        @as(u128, max_u64) + 1,
        @as(u128, 1) << 63,
        (@as(u128, 1) << 64) - 1,
        @as(u128, 1) << 64,
        (@as(u128, 1) << 64) + 1,
        @as(u128, 1) << 95,
        @as(u128, 1) << 96,
        (@as(u128, 1) << 127) - 1,
        @as(u128, 1) << 127,
        max_u128 - 1,
        max_u128,
    };

    const divisors = [_]u128{
        1,
        2,
        3,
        max_u32,
        @as(u128, max_u32) + 1,
        max_u64 - 1,
        max_u64,
        @as(u128, max_u64) + 1,
        @as(u128, 1) << 63,
        (@as(u128, 1) << 64) - 1,
        @as(u128, 1) << 64,
        (@as(u128, 1) << 64) + 1,
        @as(u128, 1) << 95,
        @as(u128, 1) << 127,
        max_u128 - 1,
        max_u128,
    };

    for (numerators) |a| {
        for (divisors) |b| {
            try expectUnsignedCase(a, b);
        }
    }

    var prng = std.Random.DefaultPrng.init(0x756e_7369_676e_32);
    const random = prng.random();
    for (0..1024) |_| {
        var b = random.int(u128);
        if (b == 0) b = 1;
        try expectUnsignedCase(random.int(u128), b);
    }
}

test "compiler_rt_ti signed division edge cases" {
    const min_i32 = std.math.minInt(i32);
    const max_i32 = std.math.maxInt(i32);
    const min_i64 = std.math.minInt(i64);
    const max_i64 = std.math.maxInt(i64);
    const min_i128 = std.math.minInt(i128);
    const max_i128 = std.math.maxInt(i128);

    const numerators = [_]i128{
        0,
        1,
        -1,
        2,
        -2,
        3,
        -3,
        min_i32,
        max_i32,
        min_i64,
        max_i64,
        -(@as(i128, 1) << 64),
        (@as(i128, 1) << 64),
        min_i128,
        min_i128 + 1,
        max_i128 - 1,
        max_i128,
    };

    const divisors = [_]i128{
        1,
        -1,
        2,
        -2,
        3,
        -3,
        min_i32,
        max_i32,
        min_i64,
        max_i64,
        -(@as(i128, 1) << 64),
        (@as(i128, 1) << 64),
        min_i128,
        min_i128 + 1,
        max_i128 - 1,
        max_i128,
    };

    for (numerators) |a| {
        for (divisors) |b| {
            if (a == min_i128 and b == -1) continue;
            try expectSignedCase(a, b);
        }
    }

    try testing.expectEqual(min_i128, __divti3(min_i128, -1));
    try testing.expectEqual(@as(i128, 0), __modti3(min_i128, -1));

    var prng = std.Random.DefaultPrng.init(0x7369_676e_6564_33);
    const random = prng.random();
    for (0..1024) |_| {
        const a = random.int(i128);
        var b = random.int(i128);
        if (b == 0) b = 1;
        if (a == min_i128 and b == -1) continue;
        try expectSignedCase(a, b);
    }
}
