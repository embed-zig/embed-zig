const std = @import("std");
const embed_crypto = @import("embed").crypto;

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

pub const rsa = struct {
    const StdRsa = Certificate.rsa;
    const PublicKey = StdRsa.PublicKey;

    fn withModulusLen(
        sig: []const u8,
        msg: []const u8,
        pk_bytes: []const u8,
        hash_type: embed_crypto.HashType,
        comptime verifyFn: fn (comptime usize, []const u8, []const u8, PublicKey, comptime type) anyerror!void,
    ) anyerror!void {
        const pk_components = try StdRsa.PublicKey.parseDer(pk_bytes);
        const modulus = pk_components.modulus;
        const exponent = pk_components.exponent;

        switch (modulus.len) {
            inline 128, 256, 384, 512 => |modulus_len| {
                const public_key = try StdRsa.PublicKey.fromBytes(exponent, modulus);
                switch (hash_type) {
                    .sha256 => try verifyFn(modulus_len, sig, msg, public_key, std.crypto.hash.sha2.Sha256),
                    .sha384 => try verifyFn(modulus_len, sig, msg, public_key, std.crypto.hash.sha2.Sha384),
                    .sha512 => try verifyFn(modulus_len, sig, msg, public_key, std.crypto.hash.sha2.Sha512),
                }
            },
            else => return error.UnsupportedModulusLength,
        }
    }

    fn dispatchPKCS1v1_5(comptime modulus_len: usize, sig: []const u8, msg: []const u8, pk: PublicKey, comptime Hash: type) anyerror!void {
        return StdRsa.PKCS1v1_5Signature.verify(modulus_len, sig[0..modulus_len].*, msg, pk, Hash);
    }

    fn dispatchPSS(comptime modulus_len: usize, sig: []const u8, msg: []const u8, pk: PublicKey, comptime Hash: type) anyerror!void {
        return StdRsa.PSSSignature.verify(modulus_len, sig[0..modulus_len].*, msg, pk, Hash);
    }

    pub fn verifyPKCS1v1_5(sig: []const u8, msg: []const u8, pk: []const u8, hash_type: embed_crypto.HashType) anyerror!void {
        return withModulusLen(sig, msg, pk, hash_type, dispatchPKCS1v1_5);
    }

    pub fn verifyPSS(sig: []const u8, msg: []const u8, pk: []const u8, hash_type: embed_crypto.HashType) anyerror!void {
        return withModulusLen(sig, msg, pk, hash_type, dispatchPSS);
    }

    pub fn parseDer(pub_key: []const u8) anyerror!embed_crypto.DerKey {
        const components = try StdRsa.PublicKey.parseDer(pub_key);
        return .{
            .modulus = components.modulus,
            .exponent = components.exponent,
        };
    }
};
