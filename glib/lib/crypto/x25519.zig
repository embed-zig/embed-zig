const std = @import("std");

pub const bytes_len = 32;
pub const base_point: [bytes_len]u8 = .{9} ++ .{0} ** (bytes_len - 1);
pub const secret_length = bytes_len;
pub const public_length = bytes_len;
pub const shared_length = bytes_len;
pub const seed_length = bytes_len;

const IdentityElementError = std.crypto.errors.IdentityElementError;

pub const KeyPair = struct {
    public_key: [public_length]u8,
    secret_key: [secret_length]u8,

    pub fn generateDeterministic(seed: [seed_length]u8) IdentityElementError!KeyPair {
        return .{
            .public_key = try recoverPublicKey(seed),
            .secret_key = seed,
        };
    }

    pub fn generate() KeyPair {
        while (true) {
            var seed: [seed_length]u8 = undefined;
            std.crypto.random.bytes(&seed);
            return generateDeterministic(seed) catch continue;
        }
    }
};

pub fn recoverPublicKey(secret_key: [secret_length]u8) IdentityElementError![public_length]u8 {
    return scalarMult(secret_key, base_point);
}

pub fn scalarmult(secret_key: [secret_length]u8, public_key: [public_length]u8) IdentityElementError![shared_length]u8 {
    var public = public_key;
    public[bytes_len - 1] &= 0x7f;
    return scalarMult(secret_key, public);
}

pub fn scalarmultBase(secret_key: [bytes_len]u8) IdentityElementError![bytes_len]u8 {
    return recoverPublicKey(secret_key);
}

const limbs_len = 8;
const Limb = u32;
const DoubleLimb = u64;
const SignedDoubleLimb = i64;
const FieldElement = [limbs_len]Limb;

const PowerStep = struct {
    a: usize,
    c: usize,
    n: usize,
};

fn scalarMult(secret_key: [bytes_len]u8, public_key: [bytes_len]u8) IdentityElementError![bytes_len]u8 {
    var xs: [5]FieldElement = undefined;
    x25519Core(&xs, secret_key, public_key);

    const steps = [_]PowerStep{
        .{ .a = 2, .c = 1, .n = 1 },
        .{ .a = 2, .c = 1, .n = 1 },
        .{ .a = 4, .c = 2, .n = 3 },
        .{ .a = 2, .c = 4, .n = 6 },
        .{ .a = 3, .c = 1, .n = 1 },
        .{ .a = 3, .c = 2, .n = 12 },
        .{ .a = 4, .c = 3, .n = 25 },
        .{ .a = 2, .c = 3, .n = 25 },
        .{ .a = 2, .c = 4, .n = 50 },
        .{ .a = 3, .c = 2, .n = 125 },
        .{ .a = 3, .c = 1, .n = 2 },
        .{ .a = 3, .c = 1, .n = 2 },
        .{ .a = 3, .c = 1, .n = 1 },
    };

    var prev: usize = 1;
    for (steps) |step| {
        var j: usize = 0;
        while (j < step.n) : (j += 1) {
            sqr(&xs[step.a], &xs[prev]);
            prev = step.a;
        }
        mulInPlace(&xs[step.a], &xs[step.c]);
    }

    mulInPlace(&xs[0], &xs[3]);
    const ret = canon(&xs[0]);
    if (ret != 0) return error.IdentityElement;
    return storeLittle(&xs[0]);
}

fn x25519Core(xs: *[5]FieldElement, scalar: [bytes_len]u8, point: [bytes_len]u8) void {
    const x1 = loadLittle(point);

    xs.* = .{ zero(), zero(), zero(), zero(), zero() };
    xs[0][0] = 1;
    xs[3][0] = 1;
    xs[2] = x1;

    var swap: Limb = 0;
    var bit_index: i32 = 255;
    while (bit_index >= 0) : (bit_index -= 1) {
        const i: usize = @intCast(bit_index);
        var byte = scalar[i / 8];
        if (i / 8 == 0) {
            byte &= ~@as(u8, 7);
        } else if (i / 8 == bytes_len - 1) {
            byte &= 0x7f;
            byte |= 0x40;
        }

        const do_swap: Limb = 0 -% @as(Limb, (byte >> @intCast(i % 8)) & 1);
        condswap(xs, swap ^ do_swap);
        swap = do_swap;

        ladderPart1(xs);
        ladderPart2(xs, &x1);
    }
    condswap(xs, swap);
}

fn ladderPart1(xs: *[5]FieldElement) void {
    add(&xs[4], &xs[0], &xs[1]);
    sub(&xs[1], &xs[0], &xs[1]);
    add(&xs[0], &xs[2], &xs[3]);
    sub(&xs[3], &xs[2], &xs[3]);
    mulInPlace(&xs[3], &xs[4]);
    mulInPlace(&xs[0], &xs[1]);
    add(&xs[2], &xs[3], &xs[0]);
    sub(&xs[3], &xs[3], &xs[0]);
    sqrInPlace(&xs[4]);
    sqrInPlace(&xs[1]);
    sub(&xs[0], &xs[4], &xs[1]);
    mulSmall(&xs[1], &xs[0], 121665);
    add(&xs[1], &xs[1], &xs[4]);
}

fn ladderPart2(xs: *[5]FieldElement, x1: *const FieldElement) void {
    sqrInPlace(&xs[3]);
    mulInPlace(&xs[3], x1);
    sqrInPlace(&xs[2]);
    mulInPlace(&xs[1], &xs[0]);
    sub(&xs[0], &xs[4], &xs[0]);
    mulInPlace(&xs[0], &xs[4]);
}

fn zero() FieldElement {
    return [_]Limb{0} ** limbs_len;
}

fn propagate(x: *FieldElement, over_in: Limb) void {
    const over = (x[limbs_len - 1] >> 31) | (over_in << 1);
    x[limbs_len - 1] &= ~(@as(Limb, 1) << 31);

    var carry: Limb = over * 19;
    for (0..limbs_len) |i| {
        x[i] = adc0(&carry, x[i]);
    }
}

fn add(out: *FieldElement, a: *const FieldElement, b: *const FieldElement) void {
    var carry: Limb = 0;
    for (0..limbs_len) |i| {
        out[i] = adc(&carry, a[i], b[i]);
    }
    propagate(out, carry);
}

fn sub(out: *FieldElement, a: *const FieldElement, b: *const FieldElement) void {
    var carry: SignedDoubleLimb = -38;
    for (0..limbs_len) |i| {
        carry = carry + @as(SignedDoubleLimb, a[i]) - @as(SignedDoubleLimb, b[i]);
        out[i] = truncateSigned(carry);
        carry >>= 32;
    }
    propagate(out, @intCast(1 + carry));
}

fn mul(out: *FieldElement, a: *const FieldElement, b: *const FieldElement, comptime n: usize) void {
    var accum = [_]Limb{0} ** (2 * limbs_len);

    for (0..n) |i| {
        var carry: Limb = 0;
        const mand = b[i];
        for (0..limbs_len) |j| {
            accum[i + j] = umaal(&carry, accum[i + j], mand, a[j]);
        }
        accum[i + limbs_len] = carry;
    }

    var carry: Limb = 0;
    for (0..limbs_len) |j| {
        out[j] = umaal(&carry, accum[j], 38, accum[j + limbs_len]);
    }
    propagate(out, carry);
}

fn mulSmall(out: *FieldElement, a: *const FieldElement, scalar: Limb) void {
    var small = zero();
    small[0] = scalar;
    mul(out, a, &small, 1);
}

fn sqr(out: *FieldElement, a: *const FieldElement) void {
    mul(out, a, a, limbs_len);
}

fn mulInPlace(out: *FieldElement, a: *const FieldElement) void {
    var tmp: FieldElement = undefined;
    mul(&tmp, a, out, limbs_len);
    out.* = tmp;
}

fn sqrInPlace(a: *FieldElement) void {
    mulInPlace(a, a);
}

fn condswap(xs: *[5]FieldElement, do_swap: Limb) void {
    for (0..2) |pair| {
        for (0..limbs_len) |i| {
            const xor = (xs[pair][i] ^ xs[pair + 2][i]) & do_swap;
            xs[pair][i] ^= xor;
            xs[pair + 2][i] ^= xor;
        }
    }
}

fn canon(x: *FieldElement) Limb {
    var carry0: Limb = 19;
    for (0..limbs_len) |i| {
        x[i] = adc0(&carry0, x[i]);
    }
    propagate(x, carry0);

    var carry: SignedDoubleLimb = -19;
    var res: Limb = 0;
    for (0..limbs_len) |i| {
        carry += x[i];
        x[i] = truncateSigned(carry);
        res |= x[i];
        carry >>= 32;
    }
    return @truncate((@as(DoubleLimb, res) -% 1) >> 32);
}

fn umaal(carry: *Limb, acc: Limb, mand: Limb, mier: Limb) Limb {
    const tmp = @as(DoubleLimb, mand) * @as(DoubleLimb, mier) + acc + carry.*;
    carry.* = @intCast(tmp >> 32);
    return @truncate(tmp);
}

fn adc(carry: *Limb, acc: Limb, mand: Limb) Limb {
    const total = @as(DoubleLimb, carry.*) + acc + mand;
    carry.* = @intCast(total >> 32);
    return @truncate(total);
}

fn adc0(carry: *Limb, acc: Limb) Limb {
    const total = @as(DoubleLimb, carry.*) + acc;
    carry.* = @intCast(total >> 32);
    return @truncate(total);
}

fn loadLittle(bytes: [bytes_len]u8) FieldElement {
    var out: FieldElement = undefined;
    for (0..limbs_len) |i| {
        out[i] = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    }
    return out;
}

fn storeLittle(x: *const FieldElement) [bytes_len]u8 {
    var out: [bytes_len]u8 = undefined;
    for (0..limbs_len) |i| {
        std.mem.writeInt(u32, out[i * 4 ..][0..4], x[i], .little);
    }
    return out;
}

fn truncateSigned(value: SignedDoubleLimb) Limb {
    return @truncate(@as(u64, @bitCast(value)));
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");
    const Cases = struct {
        fn rfc7748BasePointVector(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;

            const scalar = [_]u8{
                0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d,
                0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
                0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a,
                0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
            };
            const expected = [_]u8{
                0x85, 0x20, 0xf0, 0x09, 0x89, 0x30, 0xa7, 0x54,
                0x74, 0x8b, 0x7d, 0xdc, 0xb4, 0x3e, 0xf7, 0x5a,
                0x0d, 0xbf, 0x3a, 0x0d, 0x26, 0x38, 0x1a, 0xf4,
                0xeb, 0xa4, 0xa9, 0x8e, 0xaa, 0x9b, 0x4e, 0x6a,
            };

            const public_key = try recoverPublicKey(scalar);
            try std.testing.expectEqualSlices(u8, &expected, &public_key);
        }

        fn rfc7748Vector1(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;

            const secret_key = [_]u8{
                0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d,
                0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd,
                0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18,
                0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4,
            };
            const public_key = [_]u8{
                0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb,
                0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c,
                0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b,
                0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c,
            };
            const expected = [_]u8{
                0xc3, 0xda, 0x55, 0x37, 0x9d, 0xe9, 0xc6, 0x90,
                0x8e, 0x94, 0xea, 0x4d, 0xf2, 0x8d, 0x08, 0x4f,
                0x32, 0xec, 0xcf, 0x03, 0x49, 0x1c, 0x71, 0xf7,
                0x54, 0xb4, 0x07, 0x55, 0x77, 0xa2, 0x85, 0x52,
            };

            const out = try scalarmult(secret_key, public_key);
            try std.testing.expectEqualSlices(u8, &expected, &out);
        }

        fn rfc7748Vector2(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;

            const secret_key = [_]u8{
                0x4b, 0x66, 0xe9, 0xd4, 0xd1, 0xb4, 0x67, 0x3c,
                0x5a, 0xd2, 0x26, 0x91, 0x95, 0x7d, 0x6a, 0xf5,
                0xc1, 0x1b, 0x64, 0x21, 0xe0, 0xea, 0x01, 0xd4,
                0x2c, 0xa4, 0x16, 0x9e, 0x79, 0x18, 0xba, 0x0d,
            };
            const public_key = [_]u8{
                0xe5, 0x21, 0x0f, 0x12, 0x78, 0x68, 0x11, 0xd3,
                0xf4, 0xb7, 0x95, 0x9d, 0x05, 0x38, 0xae, 0x2c,
                0x31, 0xdb, 0xe7, 0x10, 0x6f, 0xc0, 0x3c, 0x3e,
                0xfc, 0x4c, 0xd5, 0x49, 0xc7, 0x15, 0xa4, 0x93,
            };
            const expected = [_]u8{
                0x95, 0xcb, 0xde, 0x94, 0x76, 0xe8, 0x90, 0x7d,
                0x7a, 0xad, 0xe4, 0x5c, 0xb4, 0xb8, 0x73, 0xf8,
                0x8b, 0x59, 0x5a, 0x68, 0x79, 0x9f, 0xa1, 0x52,
                0xe6, 0xf8, 0xf7, 0x64, 0x7a, 0xac, 0x79, 0x57,
            };

            const out = try scalarmult(secret_key, public_key);
            try std.testing.expectEqualSlices(u8, &expected, &out);
        }

        fn keyAgreementRoundTrip(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;

            const a_seed = [_]u8{0x11} ** bytes_len;
            const b_seed = [_]u8{0x22} ** bytes_len;
            const a = try KeyPair.generateDeterministic(a_seed);
            const b = try KeyPair.generateDeterministic(b_seed);

            const shared_a = try scalarmult(a.secret_key, b.public_key);
            const shared_b = try scalarmult(b.secret_key, a.public_key);
            try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
        }

        fn goldenVectors(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;

            // Generated from STROBE's MIT-licensed x25519.c via
            // trombik/esp_wireguard@9217c5be0836e908005301ad2c2d42009e560c0e.
            const scalar_a = [_]u8{
                0x03, 0x0a, 0x11, 0x18, 0x1f, 0x26, 0x2d, 0x34,
                0x3b, 0x42, 0x49, 0x50, 0x57, 0x5e, 0x65, 0x6c,
                0x73, 0x7a, 0x81, 0x88, 0x8f, 0x96, 0x9d, 0xa4,
                0xab, 0xb2, 0xb9, 0xc0, 0xc7, 0xce, 0xd5, 0xdc,
            };
            const scalar_b = [_]u8{
                0xf1, 0xec, 0xe7, 0xe2, 0xdd, 0xd8, 0xd3, 0xce,
                0xc9, 0xc4, 0xbf, 0xba, 0xb5, 0xb0, 0xab, 0xa6,
                0xa1, 0x9c, 0x97, 0x92, 0x8d, 0x88, 0x83, 0x7e,
                0x79, 0x74, 0x6f, 0x6a, 0x65, 0x60, 0x5b, 0x56,
            };
            const point = [_]u8{
                0x09, 0x14, 0x1f, 0x2a, 0x35, 0x40, 0x4b, 0x56,
                0x61, 0x6c, 0x77, 0x82, 0x8d, 0x98, 0xa3, 0xae,
                0xb9, 0xc4, 0xcf, 0xda, 0xe5, 0xf0, 0xfb, 0x06,
                0x11, 0x1c, 0x27, 0x32, 0x3d, 0x48, 0x53, 0x5e,
            };
            const pub_a = [_]u8{
                0xbb, 0x50, 0xff, 0x9e, 0x82, 0xa5, 0x74, 0xcf,
                0xbf, 0x82, 0x0e, 0x97, 0xf6, 0x0f, 0xb9, 0xc1,
                0x43, 0xec, 0x74, 0x15, 0xcf, 0x51, 0x4f, 0x8c,
                0xfd, 0x98, 0xef, 0xf5, 0x9e, 0x05, 0x96, 0x14,
            };
            const pub_b = [_]u8{
                0xe1, 0x90, 0x15, 0x31, 0x68, 0x3b, 0xa0, 0x53,
                0x4f, 0x23, 0x4a, 0xa1, 0x38, 0xa4, 0x37, 0x23,
                0xfe, 0x33, 0x70, 0xeb, 0x25, 0x6a, 0xd4, 0x2b,
                0xab, 0x79, 0x77, 0x35, 0x9b, 0x73, 0x47, 0x34,
            };
            const shared_ab = [_]u8{
                0x0e, 0xf5, 0x1e, 0x58, 0xc1, 0x26, 0x90, 0x37,
                0xdd, 0x80, 0x51, 0xe1, 0x0d, 0x3c, 0xa4, 0xe5,
                0x9f, 0x56, 0x1e, 0x35, 0xcc, 0x48, 0x8f, 0x51,
                0x41, 0x0c, 0x1b, 0x2b, 0x92, 0xe6, 0x0a, 0x7a,
            };
            const arbitrary_out = [_]u8{
                0x5e, 0x26, 0x27, 0xfc, 0xaf, 0x5c, 0x6a, 0x19,
                0x71, 0x12, 0x71, 0xd0, 0xbb, 0x85, 0xc3, 0x0b,
                0xd8, 0x61, 0xf0, 0x7c, 0xff, 0x16, 0x97, 0x36,
                0x95, 0x52, 0x55, 0x0f, 0xc2, 0xa3, 0xd1, 0x31,
            };

            const got_pub_a = try recoverPublicKey(scalar_a);
            const got_pub_b = try recoverPublicKey(scalar_b);
            const got_shared_ab = try scalarmult(scalar_a, pub_b);
            const got_arbitrary = try scalarmult(scalar_a, point);

            try std.testing.expectEqualSlices(u8, &pub_a, &got_pub_a);
            try std.testing.expectEqualSlices(u8, &pub_b, &got_pub_b);
            try std.testing.expectEqualSlices(u8, &shared_ab, &got_shared_ab);
            try std.testing.expectEqualSlices(u8, &arbitrary_out, &got_arbitrary);
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

            t.run("rfc7748_base_point_vector", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.rfc7748BasePointVector));
            t.run("rfc7748_vector1", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.rfc7748Vector1));
            t.run("rfc7748_vector2", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.rfc7748Vector2));
            t.run("key_agreement_round_trip", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.keyAgreementRoundTrip));
            t.run("golden_vectors", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.goldenVectors));
            return t.wait();
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
