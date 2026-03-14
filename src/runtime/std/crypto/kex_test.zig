const std = @import("std");
const module = @import("kex.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const X25519 = module.X25519;
const P256 = module.P256;

test "X25519 key exchange roundtrip" {
    const seed_a: [32]u8 = [_]u8{0x01} ** 32;
    const seed_b: [32]u8 = [_]u8{0x02} ** 32;

    const kp_a = try X25519.KeyPair.generateDeterministic(seed_a);
    const kp_b = try X25519.KeyPair.generateDeterministic(seed_b);

    const shared_a = try X25519.scalarmult(kp_a.secret_key, kp_b.public_key);
    const shared_b = try X25519.scalarmult(kp_b.secret_key, kp_a.public_key);

    try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
}
