const std = @import("std");
const glib = @import("glib");
const mbedtls = @import("mbedtls");

pub const errors = std.crypto.errors;

pub const Sha256 = mbedtls.crypto.Sha256;
pub const Sha384 = mbedtls.crypto.Sha384;
pub const Sha512 = mbedtls.crypto.Sha512;

pub const HmacSha256 = mbedtls.crypto.HmacSha256;
pub const HmacSha384 = mbedtls.crypto.HmacSha384;
pub const HmacSha512 = mbedtls.crypto.HmacSha512;

pub const Aes128Gcm = mbedtls.crypto.Aes128Gcm;
pub const Aes256Gcm = mbedtls.crypto.Aes256Gcm;
pub const ChaCha20Poly1305 = mbedtls.crypto.ChaCha20Poly1305;

pub const random = std.crypto.random;

pub const HkdfSha256 = mbedtls.crypto.HkdfSha256;
pub const HkdfSha384 = mbedtls.crypto.HkdfSha384;

pub const Ed25519 = std.crypto.sign.Ed25519;
pub const EcdsaP256Sha256 = mbedtls.crypto.EcdsaP256Sha256;
pub const EcdsaP384Sha384 = mbedtls.crypto.EcdsaP384Sha384;

pub const X25519 = glib.crypto.x25519;
pub const P256 = mbedtls.crypto.P256;

pub const has_hardware_support = mbedtls.crypto.has_hardware_support;
pub const Aes128 = mbedtls.crypto.Aes128;
pub const Aes256 = mbedtls.crypto.Aes256;

pub const Certificate = mbedtls.crypto.Certificate;
