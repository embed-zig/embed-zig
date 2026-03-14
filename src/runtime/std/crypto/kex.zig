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
