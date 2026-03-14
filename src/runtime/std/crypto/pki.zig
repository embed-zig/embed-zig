const std = @import("std");

pub const Ed25519 = struct {
    pub const Signature = std.crypto.sign.Ed25519.Signature;
    pub const PublicKey = std.crypto.sign.Ed25519.PublicKey;
    pub const SecretKey = std.crypto.sign.Ed25519.SecretKey;
    pub const KeyPair = std.crypto.sign.Ed25519.KeyPair;

    pub fn sign(key_pair: KeyPair, msg: []const u8, noise: ?[KeyPair.seed_length]u8) !Signature {
        return key_pair.sign(msg, noise);
    }

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

pub const EcdsaP256Sha256 = struct {
    const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    pub const Signature = Scheme.Signature;
    pub const PublicKey = Scheme.PublicKey;
    pub const SecretKey = Scheme.SecretKey;
    pub const KeyPair = Scheme.KeyPair;

    pub fn sign(key_pair: KeyPair, msg: []const u8, noise: ?[KeyPair.seed_length]u8) !Signature {
        return key_pair.sign(msg, noise);
    }

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

pub const EcdsaP384Sha384 = struct {
    const Scheme = std.crypto.sign.ecdsa.EcdsaP384Sha384;
    pub const Signature = Scheme.Signature;
    pub const PublicKey = Scheme.PublicKey;
    pub const SecretKey = Scheme.SecretKey;
    pub const KeyPair = Scheme.KeyPair;

    pub fn sign(key_pair: KeyPair, msg: []const u8, noise: ?[KeyPair.seed_length]u8) !Signature {
        return key_pair.sign(msg, noise);
    }

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};
