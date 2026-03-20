//! Crypto contract — platform-dependent cryptographic primitives.
//!
//! After `embed.Make(impl)`, `embed.crypto.hash.sha2.Sha256` has the
//! same API as `std.crypto.hash.sha2.Sha256`.
//!
//! Impl provides **flat types** with std-compatible function signatures.
//! `make()` verifies signatures at comptime, then wraps them into
//! `std.crypto`'s namespace tree.
//!
//! Impl must provide:
//!
//! Hash:     Sha256, Sha384, Sha512
//! HMAC:     HmacSha256, HmacSha384, HmacSha512
//! AEAD:     Aes128Gcm, Aes256Gcm, ChaCha20Poly1305
//! Random:   random (std.Random value)
//! KDF:      HkdfSha256, HkdfSha384
//! Sign:     Ed25519, EcdsaP256Sha256, EcdsaP384Sha384
//! DH:       X25519
//! ECC:      P256
//! Block:    Aes128, Aes256
//! Cert:     Certificate
//! RSA:      rsa

const std = @import("std");

const root = @This();

/// Hash algorithm selector for RSA signature verification.
pub const HashType = enum { sha256, sha384, sha512 };

/// Parsed RSA public key components from a raw DER-encoded
/// `RSAPublicKey` (RFC 8017 A.1.1): `SEQUENCE { INTEGER modulus, INTEGER exponent }`.
/// This is the inner key structure, **not** an SPKI wrapper.
pub const DerKey = struct {
    modulus: []const u8,
    exponent: []const u8,
};

pub fn make(comptime Impl: type) type {
    return struct {
        pub const hash = struct {
            pub const sha2 = struct {
                pub const Sha256 = makeHash(Impl.Sha256);
                pub const Sha384 = makeHash(Impl.Sha384);
                pub const Sha512 = makeHash(Impl.Sha512);
            };
        };
        pub const auth = struct {
            pub const hmac = struct {
                pub const sha2 = struct {
                    pub const HmacSha256 = makeHmac(Impl.HmacSha256);
                    pub const HmacSha384 = makeHmac(Impl.HmacSha384);
                    pub const HmacSha512 = makeHmac(Impl.HmacSha512);
                };
            };
        };
        pub const aead = struct {
            pub const aes_gcm = struct {
                pub const Aes128Gcm = makeAead(Impl.Aes128Gcm);
                pub const Aes256Gcm = makeAead(Impl.Aes256Gcm);
            };
            pub const chacha_poly = struct {
                pub const ChaCha20Poly1305 = makeAead(Impl.ChaCha20Poly1305);
            };
        };
        pub const random = Impl.random;
        pub const kdf = struct {
            pub const hkdf = struct {
                pub const HkdfSha256 = makeHkdf(Impl.HkdfSha256);
                pub const HkdfSha384 = makeHkdf(Impl.HkdfSha384);
            };
        };
        pub const sign = struct {
            pub const Ed25519 = makeEd25519(Impl.Ed25519);
            pub const ecdsa = struct {
                pub const EcdsaP256Sha256 = makeEcdsa(Impl.EcdsaP256Sha256);
                pub const EcdsaP384Sha384 = makeEcdsa(Impl.EcdsaP384Sha384);
            };
        };
        pub const dh = struct {
            pub const X25519 = makeX25519(Impl.X25519);
        };
        pub const ecc = struct {
            pub const P256 = makeCurve(Impl.P256);
        };
        pub const core = struct {
            pub const aes = struct {
                pub const Aes128 = makeBlockCipher(Impl.Aes128, 128);
                pub const Aes256 = makeBlockCipher(Impl.Aes256, 256);
            };
        };
        pub const Certificate = makeCertificate(Impl.Certificate);
        pub const rsa = makeRsa(Impl.rsa);
        pub const errors = std.crypto.errors;
    };
}

// ---------------------------------------------------------------------------
// makeHash — streaming hash (Sha256, Sha384, Sha512)
// ---------------------------------------------------------------------------

fn makeHash(comptime Impl: type) type {
    comptime {
        _ = @as(usize, Impl.digest_length);
        _ = @as(usize, Impl.block_length);
        _ = @as(*const fn ([]const u8, *[Impl.digest_length]u8, Impl.Options) void, &Impl.hash);
        _ = @as(*const fn (Impl.Options) Impl, &Impl.init);
        _ = @as(*const fn (*Impl, []const u8) void, &Impl.update);
        _ = @as(*const fn (*Impl, *[Impl.digest_length]u8) void, &Impl.final);
        _ = @as(*const fn (*Impl) [Impl.digest_length]u8, &Impl.finalResult);
        _ = @as(*const fn (Impl) [Impl.digest_length]u8, &Impl.peek);
    }

    return struct {
        pub const digest_length = Impl.digest_length;
        pub const block_length = Impl.block_length;
        pub const Options = Impl.Options;

        impl: Impl,

        const Self = @This();

        pub fn hash(b: []const u8, out: *[digest_length]u8, options: Options) void {
            Impl.hash(b, out, options);
        }

        pub fn init(options: Options) Self {
            return .{ .impl = Impl.init(options) };
        }

        pub fn update(self: *Self, b: []const u8) void {
            self.impl.update(b);
        }

        pub fn final(self: *Self, out: *[digest_length]u8) void {
            self.impl.final(out);
        }

        pub fn finalResult(self: *Self) [digest_length]u8 {
            return self.impl.finalResult();
        }

        pub fn peek(self: Self) [digest_length]u8 {
            return self.impl.peek();
        }
    };
}

// ---------------------------------------------------------------------------
// makeHmac — HMAC (HmacSha256, HmacSha384, HmacSha512)
// ---------------------------------------------------------------------------

fn makeHmac(comptime Impl: type) type {
    comptime {
        _ = @as(usize, Impl.mac_length);
        _ = @as(usize, Impl.key_length);
        _ = @as(usize, Impl.key_length_min);
        _ = @as(*const fn (*[Impl.mac_length]u8, []const u8, []const u8) void, &Impl.create);
        _ = @as(*const fn ([]const u8) Impl, &Impl.init);
        _ = @as(*const fn (*Impl, []const u8) void, &Impl.update);
        _ = @as(*const fn (*Impl, *[Impl.mac_length]u8) void, &Impl.final);
    }

    return struct {
        pub const mac_length = Impl.mac_length;
        pub const key_length = Impl.key_length;
        pub const key_length_min = Impl.key_length_min;

        impl: Impl,

        const Self = @This();

        pub fn create(out: *[mac_length]u8, msg: []const u8, key: []const u8) void {
            Impl.create(out, msg, key);
        }

        pub fn init(key: []const u8) Self {
            return .{ .impl = Impl.init(key) };
        }

        pub fn update(self: *Self, msg: []const u8) void {
            self.impl.update(msg);
        }

        pub fn final(self: *Self, out: *[mac_length]u8) void {
            self.impl.final(out);
        }
    };
}

// ---------------------------------------------------------------------------
// makeAead — AEAD (Aes128Gcm, Aes256Gcm, ChaCha20Poly1305)
// ---------------------------------------------------------------------------

fn makeAead(comptime Impl: type) type {
    comptime {
        _ = @as(usize, Impl.tag_length);
        _ = @as(usize, Impl.nonce_length);
        _ = @as(usize, Impl.key_length);
        _ = @as(
            *const fn ([]u8, *[Impl.tag_length]u8, []const u8, []const u8, [Impl.nonce_length]u8, [Impl.key_length]u8) void,
            &Impl.encrypt,
        );
        _ = @as(
            *const fn ([]u8, []const u8, [Impl.tag_length]u8, []const u8, [Impl.nonce_length]u8, [Impl.key_length]u8) std.crypto.errors.AuthenticationError!void,
            &Impl.decrypt,
        );
    }

    return struct {
        pub const tag_length = Impl.tag_length;
        pub const nonce_length = Impl.nonce_length;
        pub const key_length = Impl.key_length;

        pub fn encrypt(c: []u8, tag: *[tag_length]u8, m: []const u8, ad: []const u8, npub: [nonce_length]u8, key: [key_length]u8) void {
            Impl.encrypt(c, tag, m, ad, npub, key);
        }

        pub fn decrypt(m: []u8, c: []const u8, tag: [tag_length]u8, ad: []const u8, npub: [nonce_length]u8, key: [key_length]u8) std.crypto.errors.AuthenticationError!void {
            return Impl.decrypt(m, c, tag, ad, npub, key);
        }
    };
}

// ---------------------------------------------------------------------------
// makeHkdf — HKDF (HkdfSha256, HkdfSha384)
// ---------------------------------------------------------------------------

fn makeHkdf(comptime Impl: type) type {
    comptime {
        _ = @as(usize, Impl.prk_length);
        _ = @as(*const fn ([]const u8, []const u8) [Impl.prk_length]u8, &Impl.extract);
        _ = @as(*const fn ([]u8, []const u8, [Impl.prk_length]u8) void, &Impl.expand);
    }

    return struct {
        pub const prk_length = Impl.prk_length;

        pub fn extract(salt: []const u8, ikm: []const u8) [prk_length]u8 {
            return Impl.extract(salt, ikm);
        }

        pub fn expand(out: []u8, ctx: []const u8, prk: [prk_length]u8) void {
            Impl.expand(out, ctx, prk);
        }
    };
}

// ---------------------------------------------------------------------------
// makeEd25519 — Ed25519 signature scheme
// ---------------------------------------------------------------------------

fn makeEd25519(comptime Impl: type) type {
    comptime {
        _ = @as(usize, Impl.noise_length);

        const KP = Impl.KeyPair;
        _ = @as(usize, KP.seed_length);
        _ = @as(*const fn () KP, &KP.generate);

        const Sig = Impl.Signature;
        _ = @as(usize, Sig.encoded_length);
        _ = @as(*const fn ([Sig.encoded_length]u8) Sig, &Sig.fromBytes);
        _ = @as(*const fn (Sig) [Sig.encoded_length]u8, &Sig.toBytes);

        const PK = Impl.PublicKey;
        _ = @as(usize, PK.encoded_length);

        const SK = Impl.SecretKey;
        _ = @as(usize, SK.encoded_length);
    }

    return struct {
        pub const noise_length = Impl.noise_length;
        pub const KeyPair = Impl.KeyPair;
        pub const Signature = Impl.Signature;
        pub const PublicKey = Impl.PublicKey;
        pub const SecretKey = Impl.SecretKey;
    };
}

// ---------------------------------------------------------------------------
// makeEcdsa — ECDSA (EcdsaP256Sha256, EcdsaP384Sha384)
// ---------------------------------------------------------------------------

fn makeEcdsa(comptime Impl: type) type {
    comptime {
        const KP = Impl.KeyPair;
        _ = @as(usize, KP.seed_length);

        const Sig = Impl.Signature;
        _ = @as(usize, Sig.encoded_length);
        _ = @as(*const fn ([Sig.encoded_length]u8) Sig, &Sig.fromBytes);
        _ = @as(*const fn (Sig) [Sig.encoded_length]u8, &Sig.toBytes);

        const PK = Impl.PublicKey;
        _ = @as(usize, PK.compressed_sec1_encoded_length);
        _ = @as(usize, PK.uncompressed_sec1_encoded_length);

        const SK = Impl.SecretKey;
        _ = @as(usize, SK.encoded_length);
    }

    return struct {
        pub const KeyPair = Impl.KeyPair;
        pub const Signature = Impl.Signature;
        pub const PublicKey = Impl.PublicKey;
        pub const SecretKey = Impl.SecretKey;
    };
}

// ---------------------------------------------------------------------------
// makeX25519 — X25519 Diffie-Hellman key exchange
// ---------------------------------------------------------------------------

fn makeX25519(comptime Impl: type) type {
    comptime {
        _ = @as(usize, Impl.secret_length);
        _ = @as(usize, Impl.public_length);
        _ = @as(usize, Impl.shared_length);
        _ = @as(usize, Impl.seed_length);

        _ = @as(
            *const fn ([Impl.secret_length]u8) std.crypto.errors.IdentityElementError![Impl.public_length]u8,
            &Impl.recoverPublicKey,
        );
        _ = @as(
            *const fn ([Impl.secret_length]u8, [Impl.public_length]u8) std.crypto.errors.IdentityElementError![Impl.shared_length]u8,
            &Impl.scalarmult,
        );

        const KP = Impl.KeyPair;
        _ = @as(*const fn () KP, &KP.generate);
    }

    return struct {
        pub const secret_length = Impl.secret_length;
        pub const public_length = Impl.public_length;
        pub const shared_length = Impl.shared_length;
        pub const seed_length = Impl.seed_length;
        pub const KeyPair = Impl.KeyPair;

        pub fn recoverPublicKey(secret_key: [secret_length]u8) std.crypto.errors.IdentityElementError![public_length]u8 {
            return Impl.recoverPublicKey(secret_key);
        }

        pub fn scalarmult(secret_key: [secret_length]u8, public_key: [public_length]u8) std.crypto.errors.IdentityElementError![shared_length]u8 {
            return Impl.scalarmult(secret_key, public_key);
        }
    };
}

// ---------------------------------------------------------------------------
// makeCurve — Elliptic curve (P256)
// ---------------------------------------------------------------------------

fn makeCurve(comptime Impl: type) type {
    comptime {
        _ = Impl.Fe;
        _ = Impl.scalar;
        _ = Impl.basePoint;
    }

    return struct {
        pub const Fe = Impl.Fe;
        pub const scalar = Impl.scalar;
        pub const basePoint = Impl.basePoint;
    };
}

// ---------------------------------------------------------------------------
// makeBlockCipher — AES block cipher (Aes128, Aes256)
// ---------------------------------------------------------------------------

fn makeBlockCipher(comptime Impl: type, comptime expected_key_bits: usize) type {
    comptime {
        if (Impl.key_bits != expected_key_bits)
            @compileError("key_bits mismatch");

        _ = @as(*const fn (Impl.EncryptCtx, *[16]u8, *const [16]u8) void, &Impl.EncryptCtx.encrypt);
        _ = @as(*const fn (Impl.DecryptCtx, *[16]u8, *const [16]u8) void, &Impl.DecryptCtx.decrypt);
    }

    return struct {
        pub const key_bits = Impl.key_bits;
        pub const block = Impl.block;
        pub const EncryptCtx = Impl.EncryptCtx;
        pub const DecryptCtx = Impl.DecryptCtx;

        pub fn initEnc(key: [key_bits / 8]u8) EncryptCtx {
            return Impl.initEnc(key);
        }

        pub fn initDec(key: [key_bits / 8]u8) DecryptCtx {
            return Impl.initDec(key);
        }
    };
}

// ---------------------------------------------------------------------------
// makeCertificate — X.509 Certificate
// ---------------------------------------------------------------------------

fn makeCertificate(comptime Impl: type) type {
    comptime {
        _ = Impl.Version;
        _ = Impl.Algorithm;
        _ = Impl.AlgorithmCategory;
        _ = Impl.NamedCurve;
        _ = Impl.ExtensionId;
        _ = Impl.Parsed;
        _ = Impl.ParseError;
        _ = Impl.Bundle;
    }

    return struct {
        pub const Version = Impl.Version;
        pub const Algorithm = Impl.Algorithm;
        pub const AlgorithmCategory = Impl.AlgorithmCategory;
        pub const NamedCurve = Impl.NamedCurve;
        pub const ExtensionId = Impl.ExtensionId;
        pub const Parsed = Impl.Parsed;
        pub const ParseError = Impl.ParseError;
        pub const Bundle = Impl.Bundle;
    };
}

// ---------------------------------------------------------------------------
// makeRsa — RSA signature verification
// ---------------------------------------------------------------------------

fn makeRsa(comptime Impl: type) type {
    // anyerror is intentional: std's RSA verify dispatches across multiple
    // modulus lengths via inline switch, producing distinct error sets per
    // branch that cannot be unified into a single inferred set.
    comptime {
        _ = @as(*const fn ([]const u8, []const u8, []const u8, root.HashType) anyerror!void, &Impl.verifyPKCS1v1_5);
        _ = @as(*const fn ([]const u8, []const u8, []const u8, root.HashType) anyerror!void, &Impl.verifyPSS);
        _ = @as(*const fn ([]const u8) anyerror!root.DerKey, &Impl.parseDer);
    }

    return struct {
        pub const HashType = root.HashType;
        pub const DerKey = root.DerKey;

        pub fn verifyPKCS1v1_5(sig: []const u8, msg: []const u8, pk: []const u8, hash_type: root.HashType) anyerror!void {
            return Impl.verifyPKCS1v1_5(sig, msg, pk, hash_type);
        }

        pub fn verifyPSS(sig: []const u8, msg: []const u8, pk: []const u8, hash_type: root.HashType) anyerror!void {
            return Impl.verifyPSS(sig, msg, pk, hash_type);
        }

        pub fn parseDer(pub_key: []const u8) anyerror!root.DerKey {
            return Impl.parseDer(pub_key);
        }
    };
}
