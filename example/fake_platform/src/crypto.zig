const std = @import("std");

pub const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Sha384 = std.crypto.hash.sha2.Sha384;
pub const Sha512 = std.crypto.hash.sha2.Sha512;

pub const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
pub const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;
pub const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;

pub const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
pub const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
pub const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const random = std.crypto.random;

pub const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
pub const HkdfSha384 = std.crypto.kdf.hkdf.Hkdf(std.crypto.auth.hmac.sha2.HmacSha384);

pub const Ed25519 = std.crypto.sign.Ed25519;
pub const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
pub const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;

pub const X25519 = std.crypto.dh.X25519;
pub const P256 = std.crypto.ecc.P256;

const StdAes = std.crypto.core.aes;
pub const Aes128 = struct {
    pub const key_bits = StdAes.Aes128.key_bits;
    pub const block = StdAes.Aes128.block;
    pub const EncryptCtx = StdAes.AesEncryptCtx(StdAes.Aes128);
    pub const DecryptCtx = StdAes.AesDecryptCtx(StdAes.Aes128);
    pub const initEnc = StdAes.Aes128.initEnc;
    pub const initDec = StdAes.Aes128.initDec;
};
pub const Aes256 = struct {
    pub const key_bits = StdAes.Aes256.key_bits;
    pub const block = StdAes.Aes256.block;
    pub const EncryptCtx = StdAes.AesEncryptCtx(StdAes.Aes256);
    pub const DecryptCtx = StdAes.AesDecryptCtx(StdAes.Aes256);
    pub const initEnc = StdAes.Aes256.initEnc;
    pub const initDec = StdAes.Aes256.initDec;
};

pub const Certificate = std.crypto.Certificate;
