const std = @import("std");

pub const X25519 = struct {
    pub const KeyPair = struct {
        public_key: [32]u8,
        secret_key: [32]u8,

        pub fn generateDeterministic(seed: [32]u8) !KeyPair {
            const kp = try std.crypto.dh.X25519.KeyPair.generateDeterministic(seed);
            return .{
                .public_key = kp.public_key,
                .secret_key = kp.secret_key,
            };
        }
    };

    pub fn scalarmult(secret: [32]u8, public: [32]u8) ![32]u8 {
        return std.crypto.dh.X25519.scalarmult(secret, public);
    }
};

pub const P256 = struct {
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

    pub fn computePublicKey(secret_key: [32]u8) ![65]u8 {
        const kp = try Ecdsa.KeyPair.generateDeterministic(secret_key);
        return kp.public_key.toUncompressedSec1();
    }

    pub fn ecdh(secret_key: [32]u8, peer_public: [65]u8) ![32]u8 {
        const pk = Ecdsa.PublicKey.fromSec1(&peer_public) catch return error.IdentityElement;
        const mul = pk.p.mulPublic(secret_key, .big) catch return error.IdentityElement;
        return mul.affineCoordinates().x.toBytes(.big);
    }
};

test "X25519 key exchange roundtrip" {
    const seed_a: [32]u8 = [_]u8{0x01} ** 32;
    const seed_b: [32]u8 = [_]u8{0x02} ** 32;

    const kp_a = try X25519.KeyPair.generateDeterministic(seed_a);
    const kp_b = try X25519.KeyPair.generateDeterministic(seed_b);

    const shared_a = try X25519.scalarmult(kp_a.secret_key, kp_b.public_key);
    const shared_b = try X25519.scalarmult(kp_b.secret_key, kp_a.public_key);

    try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
}
