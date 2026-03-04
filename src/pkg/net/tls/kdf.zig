const std = @import("std");

/// HKDF-Expand-Label for TLS 1.3 (RFC 8446 Section 7.1).
pub fn hkdfExpandLabel(
    comptime Hkdf: type,
    secret: [Hkdf.prk_length]u8,
    comptime label: []const u8,
    context: []const u8,
    comptime len: usize,
) [len]u8 {
    const full_label = "tls13 " ++ label;

    var hkdf_label: [2 + 1 + full_label.len + 1 + 255]u8 = undefined;
    var pos: usize = 0;

    std.mem.writeInt(u16, hkdf_label[pos..][0..2], len, .big);
    pos += 2;

    hkdf_label[pos] = full_label.len;
    pos += 1;
    @memcpy(hkdf_label[pos..][0..full_label.len], full_label);
    pos += full_label.len;

    hkdf_label[pos] = @intCast(context.len);
    pos += 1;
    if (context.len > 0) {
        @memcpy(hkdf_label[pos..][0..context.len], context);
        pos += context.len;
    }

    return Hkdf.expand(&secret, hkdf_label[0..pos], len);
}

test "hkdfExpandLabel basic" {
    const Crypto = @import("runtime").std.Crypto;

    const secret: [32]u8 = [_]u8{0x01} ** 32;
    const result = hkdfExpandLabel(Crypto.HkdfSha256, secret, "key", "", 16);
    try std.testing.expect(result.len == 16);
}

test "hkdfExpandLabel with context" {
    const Crypto = @import("runtime").std.Crypto;

    const secret: [32]u8 = [_]u8{0x02} ** 32;
    const context: [32]u8 = [_]u8{0x03} ** 32;
    const result = hkdfExpandLabel(Crypto.HkdfSha256, secret, "s hs traffic", &context, 32);
    try std.testing.expect(result.len == 32);
}

test "hkdfExpandLabel different lengths" {
    const Crypto = @import("runtime").std.Crypto;

    const secret: [32]u8 = [_]u8{0x04} ** 32;

    const iv = hkdfExpandLabel(Crypto.HkdfSha256, secret, "iv", "", 12);
    try std.testing.expect(iv.len == 12);

    const key16 = hkdfExpandLabel(Crypto.HkdfSha256, secret, "key", "", 16);
    try std.testing.expect(key16.len == 16);

    const key32 = hkdfExpandLabel(Crypto.HkdfSha256, secret, "key", "", 32);
    try std.testing.expect(key32.len == 32);
}

test "hkdfExpandLabel deterministic" {
    const Crypto = @import("runtime").std.Crypto;

    const secret: [32]u8 = [_]u8{0x05} ** 32;
    const r1 = hkdfExpandLabel(Crypto.HkdfSha256, secret, "key", "", 16);
    const r2 = hkdfExpandLabel(Crypto.HkdfSha256, secret, "key", "", 16);
    try std.testing.expectEqualSlices(u8, &r1, &r2);
}

test "hkdfExpandLabel different labels produce different output" {
    const Crypto = @import("runtime").std.Crypto;

    const secret: [32]u8 = [_]u8{0x06} ** 32;
    const r1 = hkdfExpandLabel(Crypto.HkdfSha256, secret, "key", "", 32);
    const r2 = hkdfExpandLabel(Crypto.HkdfSha256, secret, "iv", "", 32);
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "hkdfExpandLabel different secrets produce different output" {
    const Crypto = @import("runtime").std.Crypto;

    const secret1: [32]u8 = [_]u8{0x07} ** 32;
    const secret2: [32]u8 = [_]u8{0x08} ** 32;
    const r1 = hkdfExpandLabel(Crypto.HkdfSha256, secret1, "key", "", 16);
    const r2 = hkdfExpandLabel(Crypto.HkdfSha256, secret2, "key", "", 16);
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "hkdfExpandLabel different contexts produce different output" {
    const Crypto = @import("runtime").std.Crypto;

    const secret: [32]u8 = [_]u8{0x09} ** 32;
    const ctx1: [16]u8 = [_]u8{0x0A} ** 16;
    const ctx2: [16]u8 = [_]u8{0x0B} ** 16;
    const r1 = hkdfExpandLabel(Crypto.HkdfSha256, secret, "key", &ctx1, 32);
    const r2 = hkdfExpandLabel(Crypto.HkdfSha256, secret, "key", &ctx2, 32);
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "hkdfExpandLabel TLS 1.3 standard labels" {
    const Crypto = @import("runtime").std.Crypto;

    const secret: [32]u8 = [_]u8{0x10} ** 32;
    const hash: [32]u8 = [_]u8{0x20} ** 32;

    const client_hs = hkdfExpandLabel(Crypto.HkdfSha256, secret, "c hs traffic", &hash, 32);
    const server_hs = hkdfExpandLabel(Crypto.HkdfSha256, secret, "s hs traffic", &hash, 32);
    try std.testing.expect(!std.mem.eql(u8, &client_hs, &server_hs));

    const client_app = hkdfExpandLabel(Crypto.HkdfSha256, secret, "c ap traffic", &hash, 32);
    const server_app = hkdfExpandLabel(Crypto.HkdfSha256, secret, "s ap traffic", &hash, 32);
    try std.testing.expect(!std.mem.eql(u8, &client_app, &server_app));
    try std.testing.expect(!std.mem.eql(u8, &client_hs, &client_app));
}

test "hkdfExpandLabel output is not all zeros" {
    const Crypto = @import("runtime").std.Crypto;

    const secret: [32]u8 = [_]u8{0x30} ** 32;
    const result = hkdfExpandLabel(Crypto.HkdfSha256, secret, "derived", "", 32);
    const all_zero = std.mem.allEqual(u8, &result, 0);
    try std.testing.expect(!all_zero);
}
