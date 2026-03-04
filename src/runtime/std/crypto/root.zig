//! std.crypto-backed runtime crypto suite (split by algorithm modules).

const std = @import("std");

const hash = @import("hash.zig");
const hmac = @import("hmac.zig");
const hkdf = @import("hkdf.zig");
const aead = @import("aead.zig");
const pki = @import("pki.zig");
const rsa_impl = @import("rsa.zig");
const kex = @import("kex.zig");

pub const Sha256 = hash.Sha256;
pub const Sha384 = hash.Sha384;
pub const Sha512 = hash.Sha512;

pub const HmacSha256 = hmac.HmacSha256;
pub const HmacSha384 = hmac.HmacSha384;
pub const HmacSha512 = hmac.HmacSha512;

pub const HkdfSha256 = hkdf.HkdfSha256;
pub const HkdfSha384 = hkdf.HkdfSha384;
pub const HkdfSha512 = hkdf.HkdfSha512;

pub const Aes128Gcm = aead.Aes128Gcm;
pub const Aes256Gcm = aead.Aes256Gcm;
pub const ChaCha20Poly1305 = aead.ChaCha20Poly1305;

pub const Ed25519 = pki.Ed25519;
pub const EcdsaP256Sha256 = pki.EcdsaP256Sha256;
pub const EcdsaP384Sha384 = pki.EcdsaP384Sha384;

pub const rsa = rsa_impl.rsa;

pub const X25519 = kex.X25519;
pub const P256 = kex.P256;

pub const Rng = struct {
    pub fn fill(buf: []u8) void {
        std.crypto.random.bytes(buf);
    }
};

pub const x509 = @import("x509.zig");

test {
    _ = @import("hash.zig");
    _ = @import("hmac.zig");
    _ = @import("hkdf.zig");
    _ = @import("aead.zig");
    _ = @import("pki.zig");
    _ = @import("rsa.zig");
    _ = @import("kex.zig");
    _ = @import("x509.zig");
}
