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
//! KDF:      HkdfSha256, HkdfSha384, hkdf.Hkdf(...)
//! Sign:     Ed25519, EcdsaP256Sha256, EcdsaP384Sha384
//! DH:       X25519
//! ECC:      P256
//! Block:    Aes128, Aes256, core.aes.has_hardware_support
//! Cert:     Certificate (including `Certificate.rsa`)

const std = @import("std");

const root = @This();

pub const errors = std.crypto.errors;

pub fn make(comptime Impl: type) type {
    return struct {
        const HashSha2 = struct {
            pub const Sha256 = makeHash(Impl.Sha256);
            pub const Sha384 = makeHash(Impl.Sha384);
            pub const Sha512 = makeHash(Impl.Sha512);
        };
        const ImplHashSha2 = struct {
            pub const Sha256 = Impl.Sha256;
            pub const Sha384 = Impl.Sha384;
            pub const Sha512 = Impl.Sha512;
        };

        pub const hash = struct {
            pub const sha2 = HashSha2;
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

                pub fn Hkdf(comptime Hmac: type) type {
                    return makeHkdf(std.crypto.kdf.hkdf.Hkdf(unwrapInnerType(Hmac)));
                }
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
                pub const has_hardware_support = Impl.has_hardware_support;
                pub const Aes128 = makeBlockCipher(Impl.Aes128, 128);
                pub const Aes256 = makeBlockCipher(Impl.Aes256, 256);
            };
        };
        pub const Certificate = makeCertificate(Impl.Certificate, HashSha2, ImplHashSha2);
        pub const errors = root.errors;
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
        pub const Inner = Impl;
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
        pub const Inner = Impl;
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

fn unwrapInnerType(comptime T: type) type {
    return if (@hasDecl(T, "Inner")) T.Inner else T;
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

fn makeCertificate(comptime Impl: type, comptime HashSha2: type, comptime ImplHashSha2: type) type {
    comptime {
        const Parsed = Impl.Parsed;
        const Bundle = Impl.Bundle;
        const ParseReturn = @typeInfo(@TypeOf(Impl.parse)).@"fn".return_type.?;
        const VerifyReturn = @typeInfo(@TypeOf(Impl.verify)).@"fn".return_type.?;
        const ParsedVerifyHostNameReturn = @typeInfo(@TypeOf(Parsed.verifyHostName)).@"fn".return_type.?;
        const ParsedVerifyReturn = @typeInfo(@TypeOf(Parsed.verify)).@"fn".return_type.?;
        const BundleVerifyReturn = @typeInfo(@TypeOf(Bundle.verify)).@"fn".return_type.?;
        const BundleRescanReturn = @typeInfo(@TypeOf(Bundle.rescan)).@"fn".return_type.?;
        _ = Impl.Version;
        _ = Impl.Algorithm;
        _ = Impl.AlgorithmCategory;
        _ = Impl.NamedCurve;
        _ = Impl.ExtensionId;
        _ = Impl.ParseError;
        _ = @as(*const fn (Impl) ParseReturn, &Impl.parse);
        _ = @as(*const fn (Impl, Impl, i64) VerifyReturn, &Impl.verify);
        _ = @as(*const fn (Parsed) []const u8, &Parsed.pubKey);
        _ = @as(*const fn (Parsed, []const u8) ParsedVerifyHostNameReturn, &Parsed.verifyHostName);
        _ = @as(*const fn (Parsed, Parsed, i64) ParsedVerifyReturn, &Parsed.verify);
        _ = @as(*const fn (Bundle, Parsed, i64) BundleVerifyReturn, &Bundle.verify);
        _ = @as(*const fn (*Bundle, std.mem.Allocator) BundleRescanReturn, &Bundle.rescan);
        _ = @as(*const fn (*Bundle, std.mem.Allocator) void, &Bundle.deinit);
        if (!@hasField(Impl, "buffer") or !@hasField(Impl, "index"))
            @compileError("Certificate must expose std-compatible buffer/index fields");
        _ = makeRsa(Impl.rsa, HashSha2, ImplHashSha2);
    }

    return struct {
        buffer: []const u8,
        index: u32,

        pub const Inner = Impl;
        pub const Version = Impl.Version;
        pub const Algorithm = Impl.Algorithm;
        pub const AlgorithmCategory = Impl.AlgorithmCategory;
        pub const NamedCurve = Impl.NamedCurve;
        pub const ExtensionId = Impl.ExtensionId;
        pub const Parsed = Impl.Parsed;
        pub const ParseError = Impl.ParseError;
        pub const Bundle = Impl.Bundle;
        pub const rsa = makeRsa(Impl.rsa, HashSha2, ImplHashSha2);

        const Self = @This();

        pub fn parse(cert: Self) @typeInfo(@TypeOf(Impl.parse)).@"fn".return_type.? {
            return Impl.parse(cert.toImpl());
        }

        pub fn verify(subject: Self, issuer: Self, now_sec: i64) @typeInfo(@TypeOf(Impl.verify)).@"fn".return_type.? {
            return Impl.verify(subject.toImpl(), issuer.toImpl(), now_sec);
        }

        fn toImpl(cert: Self) Impl {
            return .{
                .buffer = cert.buffer,
                .index = cert.index,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// makeRsa — std.crypto.Certificate.rsa-compatible namespace
// ---------------------------------------------------------------------------

fn makeRsa(comptime Impl: type, comptime HashSha2: type, comptime ImplHashSha2: type) type {
    const ImplPublicKey = Impl.PublicKey;
    const ImplPssSignature = Impl.PSSSignature;
    const ImplPkcs1Signature = Impl.PKCS1v1_5Signature;
    const ParseDerReturn = @typeInfo(@TypeOf(ImplPublicKey.parseDer)).@"fn".return_type.?;
    const FromBytesReturn = @typeInfo(@TypeOf(ImplPublicKey.fromBytes)).@"fn".return_type.?;

    comptime {
        _ = @TypeOf(ImplPssSignature.VerifyError);
        _ = @TypeOf(ImplPkcs1Signature.VerifyError);
        _ = @TypeOf(ImplPublicKey.FromBytesError);
        _ = @TypeOf(ImplPublicKey.ParseDerError);

        _ = @as(*const fn ([]const u8) ParseDerReturn, &ImplPublicKey.parseDer);
        _ = @as(*const fn ([]const u8, []const u8) FromBytesReturn, &ImplPublicKey.fromBytes);
        _ = @TypeOf(ImplPssSignature.fromBytes);
        _ = @TypeOf(ImplPssSignature.verify);
        _ = @TypeOf(ImplPssSignature.concatVerify);
        _ = @TypeOf(ImplPkcs1Signature.fromBytes);
        _ = @TypeOf(ImplPkcs1Signature.verify);
        _ = @TypeOf(ImplPkcs1Signature.concatVerify);
    }

    return struct {
        pub const PublicKey = makeRsaPublicKey(ImplPublicKey);
        pub const PSSSignature = makeRsaPssSignature(ImplPssSignature, PublicKey, HashSha2, ImplHashSha2);
        pub const PKCS1v1_5Signature = makeRsaPkcs1v15Signature(ImplPkcs1Signature, PublicKey, HashSha2, ImplHashSha2);
    };
}

fn makeRsaPublicKey(comptime Impl: type) type {
    const ParseDerReturn = @typeInfo(@TypeOf(Impl.parseDer)).@"fn".return_type.?;
    const ParseDerPayload = @typeInfo(ParseDerReturn).error_union.payload;

    return struct {
        impl: Impl,

        pub const FromBytesError = Impl.FromBytesError;
        pub const ParseDerError = Impl.ParseDerError;

        const Self = @This();

        pub fn fromBytes(pub_bytes: []const u8, modulus_bytes: []const u8) FromBytesError!Self {
            return .{ .impl = try Impl.fromBytes(pub_bytes, modulus_bytes) };
        }

        pub fn parseDer(pub_key: []const u8) ParseDerError!ParseDerPayload {
            return Impl.parseDer(pub_key);
        }
    };
}

fn makeRsaPssSignature(comptime Impl: type, comptime PublicKey: type, comptime HashSha2: type, comptime ImplHashSha2: type) type {
    return struct {
        pub const VerifyError = Impl.VerifyError;

        pub fn fromBytes(comptime modulus_len: usize, msg: []const u8) [modulus_len]u8 {
            return Impl.fromBytes(modulus_len, msg);
        }

        pub fn verify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const u8,
            public_key: PublicKey,
            comptime Hash: type,
        ) VerifyError!void {
            return Impl.verify(modulus_len, sig, msg, public_key.impl, rsaVerifyHashType(Hash, HashSha2, ImplHashSha2));
        }

        pub fn concatVerify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const []const u8,
            public_key: PublicKey,
            comptime Hash: type,
        ) VerifyError!void {
            return Impl.concatVerify(modulus_len, sig, msg, public_key.impl, rsaVerifyHashType(Hash, HashSha2, ImplHashSha2));
        }
    };
}

fn makeRsaPkcs1v15Signature(comptime Impl: type, comptime PublicKey: type, comptime HashSha2: type, comptime ImplHashSha2: type) type {
    return struct {
        pub const VerifyError = Impl.VerifyError;

        pub fn fromBytes(comptime modulus_len: usize, msg: []const u8) [modulus_len]u8 {
            return Impl.fromBytes(modulus_len, msg);
        }

        pub fn verify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const u8,
            public_key: PublicKey,
            comptime Hash: type,
        ) VerifyError!void {
            return Impl.verify(modulus_len, sig, msg, public_key.impl, rsaVerifyHashType(Hash, HashSha2, ImplHashSha2));
        }

        pub fn concatVerify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const []const u8,
            public_key: PublicKey,
            comptime Hash: type,
        ) VerifyError!void {
            return Impl.concatVerify(modulus_len, sig, msg, public_key.impl, rsaVerifyHashType(Hash, HashSha2, ImplHashSha2));
        }
    };
}

fn rsaVerifyHashType(comptime Hash: type, comptime HashSha2: type, comptime ImplHashSha2: type) type {
    if (Hash == HashSha2.Sha256 or Hash == ImplHashSha2.Sha256) return ImplHashSha2.Sha256;
    if (Hash == HashSha2.Sha384 or Hash == ImplHashSha2.Sha384) return ImplHashSha2.Sha384;
    if (Hash == HashSha2.Sha512 or Hash == ImplHashSha2.Sha512) return ImplHashSha2.Sha512;
    @compileError("RSA verification requires sha2.Sha256, sha2.Sha384, or sha2.Sha512");
}
