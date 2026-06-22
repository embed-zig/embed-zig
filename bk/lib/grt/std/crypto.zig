const std = @import("std");

pub const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Sha384 = std.crypto.hash.sha2.Sha384;
pub const Sha512 = std.crypto.hash.sha2.Sha512;

pub const HmacSha256 = std.crypto.auth.hmac.HmacSha256;
pub const HmacSha384 = std.crypto.auth.hmac.HmacSha384;
pub const HmacSha512 = std.crypto.auth.hmac.HmacSha512;

pub const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
pub const HkdfSha384 = std.crypto.kdf.hkdf.HkdfSha384;

pub const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
pub const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
pub const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const random = std.crypto.random;

pub const Ed25519 = std.crypto.sign.Ed25519;
pub const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
pub const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;

pub const X25519 = std.crypto.dh.X25519;
pub const P256 = std.crypto.ecc.P256;

pub const has_hardware_support = std.crypto.core.aes.has_hardware_support;
pub const Aes128 = std.crypto.core.aes.Aes128;
pub const Aes256 = std.crypto.core.aes.Aes256;

pub const Certificate = std.crypto.Certificate;
