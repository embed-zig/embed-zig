const std = @import("std");
const testing = std.testing;
const module = @import("pki.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Ed25519 = module.Ed25519;
const EcdsaP256Sha256 = module.EcdsaP256Sha256;
const EcdsaP384Sha384 = module.EcdsaP384Sha384;

test "pki ed25519 sign/verify" {
    const msg = "pki-ed25519-msg";
    const bad = "pki-ed25519-msg-bad";

    const seed: [Ed25519.KeyPair.seed_length]u8 = [_]u8{0x42} ** Ed25519.KeyPair.seed_length;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);

    const sig = try Ed25519.sign(kp, msg, null);
    try std.testing.expect(Ed25519.verify(sig, msg, kp.public_key));
    try std.testing.expect(!Ed25519.verify(sig, bad, kp.public_key));
}

test "pki ecdsa p256 sign/verify" {
    const msg = "pki-ecdsa-p256";
    const bad = "pki-ecdsa-p256-bad";

    const seed: [EcdsaP256Sha256.KeyPair.seed_length]u8 = [_]u8{0x23} ** EcdsaP256Sha256.KeyPair.seed_length;
    const kp = try EcdsaP256Sha256.KeyPair.generateDeterministic(seed);

    const sig = try EcdsaP256Sha256.sign(kp, msg, null);
    try std.testing.expect(EcdsaP256Sha256.verify(sig, msg, kp.public_key));
    try std.testing.expect(!EcdsaP256Sha256.verify(sig, bad, kp.public_key));
}

test "pki ecdsa p384 sign/verify" {
    const msg = "pki-ecdsa-p384";
    const bad = "pki-ecdsa-p384-bad";

    const seed: [EcdsaP384Sha384.KeyPair.seed_length]u8 = [_]u8{0x37} ** EcdsaP384Sha384.KeyPair.seed_length;
    const kp = try EcdsaP384Sha384.KeyPair.generateDeterministic(seed);

    const sig = try EcdsaP384Sha384.sign(kp, msg, null);
    try std.testing.expect(EcdsaP384Sha384.verify(sig, msg, kp.public_key));
    try std.testing.expect(!EcdsaP384Sha384.verify(sig, bad, kp.public_key));
}
