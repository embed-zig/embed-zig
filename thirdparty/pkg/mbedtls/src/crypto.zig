const aes = @import("core/aes.zig");
const chacha = @import("aead/chacha20_poly1305.zig");
const ecdsa = @import("sign/ecdsa.zig");
const gcm = @import("aead/gcm.zig");
const hkdf = @import("kdf/hkdf.zig");
const hmac = @import("mac/hmac.zig");
const p256 = @import("ecc/p256.zig");
const p384 = @import("ecc/p384.zig");
const shared = @import("shared.zig");
const sha2 = @import("hash/sha2.zig");
const x25519 = @import("dh/x25519.zig");

pub const errors = shared.errors;

pub const Sha256 = sha2.Sha256;
pub const Sha384 = sha2.Sha384;
pub const Sha512 = sha2.Sha512;

pub const HmacSha256 = hmac.HmacSha256;
pub const HmacSha384 = hmac.HmacSha384;
pub const HmacSha512 = hmac.HmacSha512;

pub const Aes128Gcm = gcm.Aes128Gcm;
pub const Aes256Gcm = gcm.Aes256Gcm;
pub const ChaCha20Poly1305 = chacha.ChaCha20Poly1305;

pub const random = @import("random.zig").random;

pub const HkdfSha256 = hkdf.HkdfSha256;
pub const HkdfSha384 = hkdf.HkdfSha384;

pub const EcdsaP256Sha256 = ecdsa.EcdsaP256Sha256;
pub const EcdsaP384Sha384 = ecdsa.EcdsaP384Sha384;

pub const X25519 = x25519.X25519;
pub const P256 = p256.P256;
pub const P384 = p384.P384;

pub const has_hardware_support = aes.has_hardware_support;
pub const Aes128 = aes.Aes128;
pub const Aes256 = aes.Aes256;

pub const Certificate = @import("Certificate.zig");
