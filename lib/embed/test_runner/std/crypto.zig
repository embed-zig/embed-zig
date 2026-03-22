const mem = @import("std").mem;

pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);

    try hashTests(lib);
    try hmacTests(lib);
    try aeadTests(lib);
    try randomTests(lib);
    try hkdfTests(lib);
    try ed25519Tests(lib);
    try ecdsaTests(lib);
    try x25519Tests(lib);
    try eccTests(lib);
    try aesBlockTests(lib);
    try certificateTests(lib);
    try certificateRsaTests(lib);

    log.info("crypto done", .{});
}

fn hashTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.hash.sha2.Sha256, 32, "sha256" },
        .{ crypto.hash.sha2.Sha384, 48, "sha384" },
        .{ crypto.hash.sha2.Sha512, 64, "sha512" },
    }) |entry| {
        const H = entry[0];
        const expected_len = entry[1];
        const name = entry[2];

        if (H.digest_length != expected_len) return error.HashDigestLenMismatch;

        var out: [H.digest_length]u8 = undefined;
        H.hash("hello", &out, .{});
        if (out[0] == 0 and out[1] == 0 and out[2] == 0 and out[3] == 0)
            return error.HashOutputAllZero;

        var h = H.init(.{});
        h.update("hel");
        h.update("lo");
        var out2: [H.digest_length]u8 = undefined;

        const peeked = h.peek();

        h.final(&out2);

        if (!mem.eql(u8, &out, &out2)) return error.HashStreamingMismatch;
        if (!mem.eql(u8, &peeked, &out)) return error.HashPeekMismatch;

        log.info("hash.sha2.{s}: digest_length={} one-shot+streaming+peek ok", .{ name, H.digest_length });
    }
}

fn hmacTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.auth.hmac.sha2.HmacSha256, 32, "HmacSha256" },
        .{ crypto.auth.hmac.sha2.HmacSha384, 48, "HmacSha384" },
        .{ crypto.auth.hmac.sha2.HmacSha512, 64, "HmacSha512" },
    }) |entry| {
        const H = entry[0];
        const expected_len = entry[1];
        const name = entry[2];

        if (H.mac_length != expected_len) return error.HmacMacLenMismatch;

        const key = "secret-key";
        const msg = "hello world";

        var out1: [H.mac_length]u8 = undefined;
        H.create(&out1, msg, key);

        var ctx = H.init(key);
        ctx.update("hello ");
        ctx.update("world");
        var out2: [H.mac_length]u8 = undefined;
        ctx.final(&out2);

        if (!mem.eql(u8, &out1, &out2)) return error.HmacStreamingMismatch;

        log.info("auth.hmac.sha2.{s}: mac_length={} create+streaming ok", .{ name, H.mac_length });
    }
}

fn aeadTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.aead.aes_gcm.Aes128Gcm, "Aes128Gcm" },
        .{ crypto.aead.aes_gcm.Aes256Gcm, "Aes256Gcm" },
        .{ crypto.aead.chacha_poly.ChaCha20Poly1305, "ChaCha20Poly1305" },
    }) |entry| {
        const A = entry[0];
        const name = entry[1];

        var key: [A.key_length]u8 = undefined;
        var nonce: [A.nonce_length]u8 = undefined;
        @memset(&key, 0x42);
        @memset(&nonce, 0x24);

        const plaintext = "crypto test msg!";
        var ciphertext: [plaintext.len]u8 = undefined;
        var tag: [A.tag_length]u8 = undefined;

        A.encrypt(&ciphertext, &tag, plaintext, "", nonce, key);

        var decrypted: [plaintext.len]u8 = undefined;
        try A.decrypt(&decrypted, &ciphertext, tag, "", nonce, key);

        if (!mem.eql(u8, plaintext, &decrypted)) return error.AeadDecryptMismatch;

        tag[0] ^= 0xff;
        if (A.decrypt(&decrypted, &ciphertext, tag, "", nonce, key)) |_| {
            return error.AeadShouldFailBadTag;
        } else |_| {}

        log.info("aead.{s}: encrypt+decrypt+auth ok", .{name});
    }
}

fn randomTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    lib.crypto.random.bytes(&buf1);
    lib.crypto.random.bytes(&buf2);

    if (mem.eql(u8, &buf1, &buf2)) return error.RandomNotRandom;

    log.info("random: 32 bytes x2 differ ok", .{});
}

fn hkdfTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.kdf.hkdf.HkdfSha256, "HkdfSha256" },
    }) |entry| {
        const H = entry[0];
        const name = entry[1];

        const salt = "salt-value";
        const ikm = "input-keying-material";
        const prk = H.extract(salt, ikm);

        if (prk.len != H.prk_length) return error.HkdfPrkLenMismatch;

        var okm: [64]u8 = undefined;
        H.expand(&okm, "info", prk);

        var all_zero = true;
        for (okm) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) return error.HkdfOutputAllZero;

        log.info("kdf.hkdf.{s}: extract+expand ok", .{name});
    }
}

fn ed25519Tests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const Ed = lib.crypto.sign.Ed25519;

    if (Ed.noise_length != 32) return error.Ed25519NoiseLenWrong;
    if (Ed.KeyPair.seed_length != 32) return error.Ed25519SeedLenWrong;
    if (Ed.Signature.encoded_length != 64) return error.Ed25519SigLenWrong;
    if (Ed.PublicKey.encoded_length != 32) return error.Ed25519PkLenWrong;
    if (Ed.SecretKey.encoded_length != 64) return error.Ed25519SkLenWrong;

    const kp = Ed.KeyPair.generate();
    const msg = "sign this message";
    const sig = kp.sign(msg, null) catch return error.Ed25519SignFailed;

    sig.verify(msg, kp.public_key) catch return error.Ed25519VerifyFailed;

    const sig_bytes = sig.toBytes();
    const sig2 = Ed.Signature.fromBytes(sig_bytes);
    if (!mem.eql(u8, &sig_bytes, &sig2.toBytes())) return error.Ed25519SigRoundtripFailed;

    log.info("sign.Ed25519: generate+sign+verify+roundtrip ok", .{});
}

fn ecdsaTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const crypto = lib.crypto;

    inline for (.{
        .{ crypto.sign.ecdsa.EcdsaP256Sha256, "EcdsaP256Sha256" },
        .{ crypto.sign.ecdsa.EcdsaP384Sha384, "EcdsaP384Sha384" },
    }) |entry| {
        const E = entry[0];
        const name = entry[1];

        _ = E.KeyPair.seed_length;
        _ = E.Signature.encoded_length;
        _ = E.PublicKey.compressed_sec1_encoded_length;
        _ = E.PublicKey.uncompressed_sec1_encoded_length;
        _ = E.SecretKey.encoded_length;

        const sig_bytes = [_]u8{0} ** E.Signature.encoded_length;
        const sig = E.Signature.fromBytes(sig_bytes);
        const rt = sig.toBytes();
        if (!mem.eql(u8, &sig_bytes, &rt)) return error.EcdsaSigRoundtripFailed;

        log.info("sign.ecdsa.{s}: constants+roundtrip ok", .{name});
    }
}

fn x25519Tests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const X = lib.crypto.dh.X25519;

    if (X.secret_length != 32) return error.X25519SecretLenWrong;
    if (X.public_length != 32) return error.X25519PublicLenWrong;
    if (X.shared_length != 32) return error.X25519SharedLenWrong;
    if (X.seed_length != 32) return error.X25519SeedLenWrong;

    const kp_a = X.KeyPair.generate();
    const kp_b = X.KeyPair.generate();

    const shared_a = try X.scalarmult(kp_a.secret_key, kp_b.public_key);
    const shared_b = try X.scalarmult(kp_b.secret_key, kp_a.public_key);

    if (!mem.eql(u8, &shared_a, &shared_b)) return error.X25519SharedMismatch;

    const recovered = try X.recoverPublicKey(kp_a.secret_key);
    if (!mem.eql(u8, &recovered, &kp_a.public_key)) return error.X25519RecoverMismatch;

    log.info("dh.X25519: generate+scalarmult+recoverPublicKey ok", .{});
}

fn eccTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const P = lib.crypto.ecc.P256;

    _ = P.Fe;
    _ = P.scalar;
    _ = P.basePoint;

    log.info("ecc.P256: Fe+scalar+basePoint present", .{});
}

fn aesBlockTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const aes = lib.crypto.core.aes;

    inline for (.{
        .{ aes.Aes128, 128, "Aes128" },
        .{ aes.Aes256, 256, "Aes256" },
    }) |entry| {
        const A = entry[0];
        const expected_bits = entry[1];
        const name = entry[2];

        if (A.key_bits != expected_bits) return error.AesKeyBitsMismatch;

        var key: [A.key_bits / 8]u8 = undefined;
        @memset(&key, 0xAB);

        const plaintext: [16]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        var encrypted: [16]u8 = undefined;
        var decrypted: [16]u8 = undefined;

        const enc_ctx = A.initEnc(key);
        enc_ctx.encrypt(&encrypted, &plaintext);

        const dec_ctx = A.initDec(key);
        dec_ctx.decrypt(&decrypted, &encrypted);

        if (!mem.eql(u8, &plaintext, &decrypted)) return error.AesBlockRoundtripFailed;

        log.info("core.aes.{s}: encrypt+decrypt block ok", .{name});
    }
}

fn certificateTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const Cert = lib.crypto.Certificate;

    _ = Cert.Version;
    _ = Cert.Algorithm;
    _ = Cert.AlgorithmCategory;
    _ = Cert.NamedCurve;
    _ = Cert.ExtensionId;
    _ = Cert.Parsed;
    _ = Cert.ParseError;
    _ = Cert.Bundle;

    const cert: Cert = .{
        .buffer = &self_signed_cert_der,
        .index = 0,
    };
    const parsed = try cert.parse();
    try parsed.verifyHostName("example.com");

    if (parsed.verifyHostName("wrong.example.com")) |_| {
        return error.CertificateVerifyHostNameShouldFail;
    } else |_| {}

    const validity_span = parsed.validity.not_after - parsed.validity.not_before;
    const valid_midpoint: i64 = @intCast(parsed.validity.not_before + @divTrunc(validity_span, 2));
    try cert.verify(cert, valid_midpoint);

    log.info("Certificate: parse+verify+verifyHostName ok", .{});
}

fn certificateRsaTests(comptime lib: type) !void {
    const log = lib.log.scoped(.crypto);
    const Rsa = lib.crypto.Certificate.rsa;
    const Sha2 = lib.crypto.hash.sha2;

    const components = try Rsa.PublicKey.parseDer(&rsa_test_pub_der);
    if (components.modulus.len != 128) return error.RsaModulusLenMismatch;
    if (components.exponent.len != 3) return error.RsaExponentLenMismatch;
    if (components.exponent[0] != 0x01 or components.exponent[1] != 0x00 or components.exponent[2] != 0x01)
        return error.RsaExponentValueMismatch;

    try verifyCertificatePkcs1v15(Rsa, Sha2, &rsa_test_sig_pkcs1, &rsa_test_msg, &rsa_test_pub_der, .sha256);
    try verifyCertificatePss(Rsa, Sha2, &rsa_test_sig_pss, &rsa_test_msg, &rsa_test_pub_der, .sha256);

    {
        var bad_msg = rsa_test_msg;
        bad_msg[0] ^= 0xff;
        if (verifyCertificatePkcs1v15(Rsa, Sha2, &rsa_test_sig_pkcs1, &bad_msg, &rsa_test_pub_der, .sha256)) |_|
            return error.RsaPkcs1TamperedMsgShouldFail
        else |_| {}
    }

    {
        var bad_sig = rsa_test_sig_pkcs1;
        bad_sig[0] ^= 0xff;
        if (verifyCertificatePkcs1v15(Rsa, Sha2, &bad_sig, &rsa_test_msg, &rsa_test_pub_der, .sha256)) |_|
            return error.RsaPkcs1TamperedSigShouldFail
        else |_| {}
    }

    {
        var bad_msg = rsa_test_msg;
        bad_msg[0] ^= 0xff;
        if (verifyCertificatePss(Rsa, Sha2, &rsa_test_sig_pss, &bad_msg, &rsa_test_pub_der, .sha256)) |_|
            return error.RsaPssTamperedMsgShouldFail
        else |_| {}
    }

    {
        var bad_sig = rsa_test_sig_pss;
        bad_sig[0] ^= 0xff;
        if (verifyCertificatePss(Rsa, Sha2, &bad_sig, &rsa_test_msg, &rsa_test_pub_der, .sha256)) |_|
            return error.RsaPssTamperedSigShouldFail
        else |_| {}
    }

    {
        const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        if (Rsa.PublicKey.parseDer(&garbage)) |_|
            return error.RsaParseDerShouldFail
        else |_| {}
    }

    if (verifyCertificatePkcs1v15(Rsa, Sha2, &rsa_test_sig_pkcs1, &rsa_test_msg, &rsa_test_pub_der, .sha512)) |_|
        return error.RsaWrongHashShouldFail
    else |_| {}

    log.info("Certificate.rsa: parseDer+PKCS1v1_5+PSS ok", .{});
}

const RsaHash = enum { sha256, sha384, sha512 };

fn verifyCertificatePkcs1v15(
    comptime Rsa: type,
    comptime Sha2: type,
    signature: []const u8,
    message: []const u8,
    pub_key: []const u8,
    hash: RsaHash,
) anyerror!void {
    return verifyCertificateRsa(Rsa, Sha2, signature, message, pub_key, hash, false);
}

fn verifyCertificatePss(
    comptime Rsa: type,
    comptime Sha2: type,
    signature: []const u8,
    message: []const u8,
    pub_key: []const u8,
    hash: RsaHash,
) anyerror!void {
    return verifyCertificateRsa(Rsa, Sha2, signature, message, pub_key, hash, true);
}

fn verifyCertificateRsa(
    comptime Rsa: type,
    comptime Sha2: type,
    signature: []const u8,
    message: []const u8,
    pub_key: []const u8,
    hash: RsaHash,
    use_pss: bool,
) anyerror!void {
    const components = try Rsa.PublicKey.parseDer(pub_key);
    switch (components.modulus.len) {
        inline 128, 256, 384, 512 => |modulus_len| {
            const key = try Rsa.PublicKey.fromBytes(components.exponent, components.modulus);
            if (use_pss) {
                const sig = Rsa.PSSSignature.fromBytes(modulus_len, signature);
                switch (hash) {
                    .sha256 => try Rsa.PSSSignature.concatVerify(modulus_len, sig, &.{message}, key, Sha2.Sha256),
                    .sha384 => try Rsa.PSSSignature.concatVerify(modulus_len, sig, &.{message}, key, Sha2.Sha384),
                    .sha512 => try Rsa.PSSSignature.concatVerify(modulus_len, sig, &.{message}, key, Sha2.Sha512),
                }
            } else {
                const sig = Rsa.PKCS1v1_5Signature.fromBytes(modulus_len, signature);
                switch (hash) {
                    .sha256 => try Rsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig, &.{message}, key, Sha2.Sha256),
                    .sha384 => try Rsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig, &.{message}, key, Sha2.Sha384),
                    .sha512 => try Rsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig, &.{message}, key, Sha2.Sha512),
                }
            }
        },
        else => return error.UnsupportedRsaModulusLength,
    }
}

const self_signed_cert_der = [_]u8{
    0x30, 0x82, 0x01, 0x99, 0x30, 0x82, 0x01, 0x3f, 0xa0, 0x03, 0x02, 0x01,
    0x02, 0x02, 0x14, 0x1f, 0x30, 0x92, 0xee, 0x83, 0xf5, 0xf2, 0x00, 0x6f,
    0xb4, 0x18, 0xb5, 0xae, 0x64, 0x0a, 0x3d, 0x88, 0x40, 0xb3, 0xc9, 0x30,
    0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x30,
    0x16, 0x31, 0x14, 0x30, 0x12, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x0b,
    0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d, 0x30,
    0x1e, 0x17, 0x0d, 0x32, 0x36, 0x30, 0x33, 0x32, 0x31, 0x31, 0x38, 0x30,
    0x37, 0x34, 0x39, 0x5a, 0x17, 0x0d, 0x33, 0x36, 0x30, 0x33, 0x31, 0x38,
    0x31, 0x38, 0x30, 0x37, 0x34, 0x39, 0x5a, 0x30, 0x16, 0x31, 0x14, 0x30,
    0x12, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x0b, 0x65, 0x78, 0x61, 0x6d,
    0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d, 0x30, 0x59, 0x30, 0x13, 0x06,
    0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86,
    0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04, 0xbc, 0x8a,
    0x8d, 0xd7, 0xa0, 0x7a, 0xe8, 0x75, 0x7a, 0x28, 0x97, 0xa3, 0xea, 0x6d,
    0xdf, 0x70, 0x4f, 0xd1, 0x75, 0x8b, 0xbb, 0xd8, 0xac, 0xbb, 0xf6, 0x1d,
    0x74, 0x3d, 0x4b, 0x1a, 0xeb, 0x38, 0x29, 0xa7, 0x3e, 0x7a, 0x9b, 0x69,
    0x6f, 0x71, 0x8c, 0xd3, 0x47, 0xb6, 0xda, 0xdc, 0xa4, 0xf1, 0x1d, 0xad,
    0xfc, 0x69, 0x23, 0x63, 0x3d, 0xfc, 0x47, 0x94, 0x71, 0x16, 0xb8, 0xae,
    0xde, 0x24, 0xa3, 0x6b, 0x30, 0x69, 0x30, 0x1d, 0x06, 0x03, 0x55, 0x1d,
    0x0e, 0x04, 0x16, 0x04, 0x14, 0x0a, 0xe2, 0x83, 0x3c, 0xd7, 0x9b, 0xd6,
    0x53, 0x6a, 0xd1, 0xda, 0x5d, 0x59, 0x4f, 0x18, 0xbe, 0x39, 0xff, 0x12,
    0xe7, 0x30, 0x1f, 0x06, 0x03, 0x55, 0x1d, 0x23, 0x04, 0x18, 0x30, 0x16,
    0x80, 0x14, 0x0a, 0xe2, 0x83, 0x3c, 0xd7, 0x9b, 0xd6, 0x53, 0x6a, 0xd1,
    0xda, 0x5d, 0x59, 0x4f, 0x18, 0xbe, 0x39, 0xff, 0x12, 0xe7, 0x30, 0x0f,
    0x06, 0x03, 0x55, 0x1d, 0x13, 0x01, 0x01, 0xff, 0x04, 0x05, 0x30, 0x03,
    0x01, 0x01, 0xff, 0x30, 0x16, 0x06, 0x03, 0x55, 0x1d, 0x11, 0x04, 0x0f,
    0x30, 0x0d, 0x82, 0x0b, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e,
    0x63, 0x6f, 0x6d, 0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
    0x04, 0x03, 0x02, 0x03, 0x48, 0x00, 0x30, 0x45, 0x02, 0x20, 0x40, 0xb6,
    0x99, 0xa2, 0x64, 0x0f, 0x19, 0x85, 0xe5, 0x90, 0xc5, 0x2e, 0x5f, 0x2c,
    0x7d, 0xab, 0x61, 0x04, 0x99, 0x40, 0x94, 0x7a, 0x2c, 0x50, 0x88, 0xf9,
    0xc1, 0x60, 0xcc, 0x34, 0x79, 0xf4, 0x02, 0x21, 0x00, 0x88, 0x86, 0xf0,
    0xb9, 0xb2, 0x07, 0x25, 0x57, 0x55, 0x60, 0x83, 0xe1, 0x9a, 0x4d, 0x20,
    0x8f, 0xaa, 0x39, 0xfe, 0xe5, 0xd8, 0x5f, 0xfc, 0x10, 0xfe, 0xd4, 0xb3,
    0x09, 0xd3, 0x38, 0xda, 0x05,
};

const rsa_test_msg = [_]u8{ 0x74, 0x65, 0x73, 0x74, 0x20, 0x6d, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x20, 0x66, 0x6f, 0x72, 0x20, 0x52, 0x53, 0x41, 0x0a };

const rsa_test_pub_der = [_]u8{
    0x30, 0x81, 0x89, 0x02, 0x81, 0x81, 0x00, 0x9c, 0xe2, 0x2d, 0xa3, 0xdb,
    0xf7, 0xca, 0xb5, 0xb5, 0x49, 0x37, 0x92, 0xe1, 0x06, 0x4a, 0x5f, 0xdd,
    0x7e, 0x89, 0x23, 0x1c, 0xd4, 0xf4, 0xb9, 0x66, 0xb3, 0xa1, 0x7e, 0xef,
    0x95, 0x6d, 0x04, 0xb3, 0xf8, 0x09, 0x43, 0xd3, 0xff, 0x11, 0x76, 0x43,
    0x6e, 0x1b, 0x58, 0xd3, 0xf8, 0x41, 0xca, 0x0c, 0xb5, 0xfd, 0x8c, 0x9d,
    0x39, 0x67, 0x46, 0x79, 0xd2, 0x90, 0x12, 0x01, 0xf8, 0xff, 0xbe, 0xbe,
    0x26, 0x73, 0xf7, 0x34, 0xa0, 0xec, 0xbf, 0x9d, 0xf0, 0x2c, 0x13, 0xf1,
    0x7a, 0x4d, 0x5f, 0x1f, 0xd0, 0x4d, 0x20, 0x32, 0xd0, 0xa9, 0x56, 0x98,
    0x43, 0x2e, 0x3b, 0x48, 0xb9, 0xab, 0xcc, 0x90, 0x85, 0xca, 0x49, 0x9a,
    0x20, 0xf0, 0xd2, 0x64, 0x75, 0xfe, 0x8e, 0x70, 0x77, 0x72, 0x6c, 0x5f,
    0x67, 0x80, 0x8c, 0x8b, 0xa8, 0x5b, 0x83, 0xca, 0x9d, 0xb5, 0xd9, 0xae,
    0xff, 0xdd, 0xf1, 0x02, 0x03, 0x01, 0x00, 0x01,
};

const rsa_test_sig_pkcs1 = [_]u8{
    0x33, 0x75, 0xa0, 0xa6, 0x45, 0x67, 0x65, 0x62, 0xf1, 0xd1, 0xd5, 0x3f,
    0x53, 0x97, 0x56, 0xee, 0x49, 0x3e, 0x6f, 0xcf, 0x43, 0xad, 0x6e, 0x60,
    0x27, 0x5a, 0xa6, 0x63, 0x9e, 0xf9, 0x56, 0xc3, 0xde, 0x75, 0xd2, 0x1a,
    0x91, 0x63, 0x97, 0xcd, 0xf0, 0x16, 0x21, 0x62, 0x9d, 0xa8, 0x88, 0x82,
    0x8c, 0x5a, 0x74, 0x2a, 0x1b, 0x73, 0xff, 0x44, 0x71, 0x22, 0x3b, 0xc5,
    0x20, 0xbf, 0x7e, 0xba, 0x2f, 0xa3, 0xe9, 0xae, 0x8e, 0x2e, 0xbd, 0x9f,
    0xc6, 0x19, 0xf4, 0x17, 0xd8, 0x99, 0x58, 0x8a, 0x14, 0x16, 0xca, 0x9c,
    0xf9, 0xb6, 0xb6, 0x10, 0x28, 0x66, 0x34, 0xc8, 0xcf, 0xc2, 0x2f, 0x6f,
    0x53, 0xff, 0x17, 0x51, 0xfb, 0x80, 0x3d, 0x27, 0xcd, 0xba, 0x1d, 0xeb,
    0x29, 0xc5, 0xf6, 0x66, 0x8f, 0xe1, 0x58, 0x00, 0x7e, 0x49, 0x0d, 0xcf,
    0x74, 0xf6, 0x30, 0x8e, 0x60, 0xd5, 0xe0, 0x14,
};

const rsa_test_sig_pss = [_]u8{
    0x05, 0x52, 0x6c, 0xc8, 0x05, 0xf8, 0x71, 0x1a, 0x7f, 0xfe, 0x27, 0xa0,
    0x8c, 0x94, 0x1a, 0x8b, 0xea, 0xa5, 0x5b, 0x2d, 0xb4, 0x39, 0xb8, 0xb4,
    0xcf, 0x9d, 0xdc, 0x95, 0x0d, 0x1a, 0x1a, 0x6e, 0xf9, 0x31, 0xbd, 0x28,
    0x13, 0x0b, 0xf8, 0x44, 0x55, 0x0c, 0x2a, 0x00, 0x31, 0xa4, 0x9f, 0x3f,
    0x49, 0x7a, 0x1e, 0x18, 0x1d, 0xce, 0xf8, 0xf9, 0x6f, 0x05, 0x8f, 0x3b,
    0x0d, 0xbc, 0x29, 0xef, 0xe5, 0x5c, 0x24, 0xba, 0x66, 0x65, 0x3d, 0xe6,
    0xe4, 0x3c, 0x02, 0xbc, 0x0b, 0x6b, 0x77, 0xd7, 0x2f, 0x16, 0x07, 0x15,
    0x70, 0x42, 0x70, 0x65, 0xf0, 0xc8, 0x2c, 0x65, 0x54, 0xec, 0x24, 0x13,
    0x07, 0x59, 0x33, 0x36, 0x53, 0x1d, 0xfb, 0xe9, 0x52, 0xc9, 0xcf, 0xca,
    0x8e, 0x0a, 0x6b, 0xde, 0x1a, 0xc0, 0x5f, 0x82, 0xe3, 0x98, 0xba, 0x34,
    0x1d, 0x05, 0x44, 0x24, 0xa6, 0xe4, 0x2b, 0xdb,
};
