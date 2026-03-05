//! PKI / digital signatures - ESP32 mbedTLS implementation.
//!
//! ECDSA P-256/P-384 verification via mbedTLS ECP/MPI.
//! Ed25519 is a stub (not available in mbedTLS; ESP32 does not support it natively).
//! RSA PKCS#1 v1.5 and PSS verification via C helper.

const mbed = @import("esp").mbedtls.mbed_tls;
const hash_mod = @import("hash.zig");

// ============================================================================
// ECDSA P-256 with SHA-256
// ============================================================================

pub const EcdsaP256Sha256 = struct {
    pub const Signature = struct {
        r: [32]u8,
        s: [32]u8,

        pub fn fromDer(der: []const u8) !Signature {
            const parsed = try parseDerSignature(32, der);
            return Signature{ .r = parsed.r, .s = parsed.s };
        }

        pub fn verify(self: Signature, msg: []const u8, pk: PublicKey) !void {
            var msg_hash: [32]u8 = undefined;
            hash_mod.Sha256.hash(msg, &msg_hash);
            try ecdsaVerify(mbed.MBEDTLS_ECP_DP_SECP256R1, &msg_hash, 32, &self.r, &self.s, 32, &pk.bytes, pk.bytes.len);
        }
    };

    pub const PublicKey = struct {
        bytes: [65]u8,

        pub fn fromSec1(sec1: []const u8) !PublicKey {
            if (sec1.len != 65 or sec1[0] != 0x04) return error.InvalidEncoding;
            var pk = PublicKey{ .bytes = undefined };
            @memcpy(&pk.bytes, sec1[0..65]);
            return pk;
        }
    };

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

// ============================================================================
// ECDSA P-384 with SHA-384
// ============================================================================

pub const EcdsaP384Sha384 = struct {
    pub const Signature = struct {
        r: [48]u8,
        s: [48]u8,

        pub fn fromDer(der: []const u8) !Signature {
            const parsed = try parseDerSignature(48, der);
            return Signature{ .r = parsed.r, .s = parsed.s };
        }

        pub fn verify(self: Signature, msg: []const u8, pk: PublicKey) !void {
            var msg_hash: [48]u8 = undefined;
            hash_mod.Sha384.hash(msg, &msg_hash);
            try ecdsaVerify(mbed.MBEDTLS_ECP_DP_SECP384R1, &msg_hash, 48, &self.r, &self.s, 48, &pk.bytes, pk.bytes.len);
        }
    };

    pub const PublicKey = struct {
        bytes: [97]u8,

        pub fn fromSec1(sec1: []const u8) !PublicKey {
            if (sec1.len != 97 or sec1[0] != 0x04) return error.InvalidEncoding;
            var pk = PublicKey{ .bytes = undefined };
            @memcpy(&pk.bytes, sec1[0..97]);
            return pk;
        }
    };

    pub fn verify(sig: Signature, msg: []const u8, pk: PublicKey) bool {
        sig.verify(msg, pk) catch return false;
        return true;
    }
};

// ============================================================================
// Ed25519 (stub - not available via mbedTLS on ESP32)
// ============================================================================

pub const Ed25519 = struct {
    pub const Signature = struct {};
    pub const PublicKey = struct {};

    pub fn verify(_: Signature, _: []const u8, _: PublicKey) bool {
        return false;
    }
};

// ============================================================================
// RSA Signatures
// ============================================================================

extern fn rsa_pkcs1v15_verify(
    modulus: [*]const u8,
    modulus_len: usize,
    exponent: [*]const u8,
    exponent_len: usize,
    hash_val: [*]const u8,
    hash_len: usize,
    signature: [*]const u8,
    hash_id: c_int,
) c_int;

extern fn rsa_pss_verify(
    modulus: [*]const u8,
    modulus_len: usize,
    exponent: [*]const u8,
    exponent_len: usize,
    hash_val: [*]const u8,
    hash_len: usize,
    signature: [*]const u8,
    hash_id: c_int,
) c_int;

pub const rsa = struct {
    pub const HashType = enum { sha256, sha384, sha512 };

    const RsaHashId = enum(c_int) { sha256 = 0, sha384 = 1, sha512 = 2 };

    pub const PublicKey = struct {
        n: []const u8,
        e: []const u8,

        pub fn parseDer(der: []const u8) !struct { modulus: []const u8, exponent: []const u8 } {
            if (der.len < 4) return error.CertificatePublicKeyInvalid;
            if (der[0] != 0x30) return error.CertificatePublicKeyInvalid;

            var pos: usize = 2;
            if (der[1] & 0x80 != 0) {
                const len_bytes = der[1] & 0x7f;
                pos = 2 + len_bytes;
            }

            if (pos >= der.len or der[pos] != 0x02) return error.CertificatePublicKeyInvalid;
            pos += 1;
            var n_len: usize = der[pos];
            pos += 1;
            if (n_len & 0x80 != 0) {
                const len_bytes = n_len & 0x7f;
                n_len = 0;
                for (der[pos..][0..len_bytes]) |b| {
                    n_len = (n_len << 8) | b;
                }
                pos += len_bytes;
            }
            while (n_len > 0 and der[pos] == 0) {
                pos += 1;
                n_len -= 1;
            }
            const modulus = der[pos..][0..n_len];
            pos += n_len;

            if (pos >= der.len or der[pos] != 0x02) return error.CertificatePublicKeyInvalid;
            pos += 1;
            var e_len: usize = der[pos];
            pos += 1;
            if (e_len & 0x80 != 0) {
                const len_bytes = e_len & 0x7f;
                e_len = 0;
                for (der[pos..][0..len_bytes]) |b| {
                    e_len = (e_len << 8) | b;
                }
                pos += len_bytes;
            }
            const exponent = der[pos..][0..e_len];

            return .{ .modulus = modulus, .exponent = exponent };
        }

        pub fn fromBytes(exponent: []const u8, modulus: []const u8) !PublicKey {
            return PublicKey{ .n = modulus, .e = exponent };
        }
    };

    fn computeHash(
        comptime hash_type: HashType,
        msg: []const u8,
        hash_buf: *[64]u8,
    ) struct { hash_slice: []const u8, hash_id: RsaHashId } {
        switch (hash_type) {
            .sha256 => {
                hash_mod.Sha256.hash(msg, hash_buf[0..32]);
                return .{ .hash_slice = hash_buf[0..32], .hash_id = .sha256 };
            },
            .sha384 => {
                hash_mod.Sha384.hash(msg, hash_buf[0..48]);
                return .{ .hash_slice = hash_buf[0..48], .hash_id = .sha384 };
            },
            .sha512 => {
                hash_mod.Sha512.hash(msg, hash_buf);
                return .{ .hash_slice = hash_buf[0..64], .hash_id = .sha512 };
            },
        }
    }

    pub const PKCS1v1_5Signature = struct {
        pub fn verify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const u8,
            pk: PublicKey,
            comptime hash_type: HashType,
        ) !void {
            var hash_buf: [64]u8 = undefined;
            const result = computeHash(hash_type, msg, &hash_buf);
            const ret = rsa_pkcs1v15_verify(
                pk.n.ptr,
                pk.n.len,
                pk.e.ptr,
                pk.e.len,
                result.hash_slice.ptr,
                result.hash_slice.len,
                &sig,
                @intFromEnum(result.hash_id),
            );
            if (ret != 0) return error.SignatureVerificationFailed;
        }
    };

    pub const PSSSignature = struct {
        pub fn verify(
            comptime modulus_len: usize,
            sig: [modulus_len]u8,
            msg: []const u8,
            pk: PublicKey,
            comptime hash_type: HashType,
        ) !void {
            var hash_buf: [64]u8 = undefined;
            const result = computeHash(hash_type, msg, &hash_buf);
            const ret = rsa_pss_verify(
                pk.n.ptr,
                pk.n.len,
                pk.e.ptr,
                pk.e.len,
                result.hash_slice.ptr,
                result.hash_slice.len,
                &sig,
                @intFromEnum(result.hash_id),
            );
            if (ret != 0) return error.SignatureVerificationFailed;
        }
    };
};

// ============================================================================
// Shared helpers
// ============================================================================

fn ecdsaVerify(
    grp_id: c_int,
    msg_hash: [*]const u8,
    hash_len: usize,
    r_bytes: [*]const u8,
    s_bytes: [*]const u8,
    scalar_len: usize,
    pk_bytes: [*]const u8,
    pk_len: usize,
) !void {
    var grp: mbed.mbedtls_ecp_group = undefined;
    mbed.ecp_group_init(&grp);
    defer mbed.ecp_group_free(&grp);

    if (mbed.ecp_group_load(&grp, grp_id) != 0)
        return error.SignatureVerificationFailed;

    var Q: mbed.mbedtls_ecp_point = undefined;
    mbed.ecp_point_init(&Q);
    defer mbed.ecp_point_free(&Q);

    if (mbed.ecp_point_read_binary(&grp, &Q, pk_bytes, pk_len) != 0)
        return error.InvalidPublicKey;

    var r_mpi: mbed.mbedtls_mpi = undefined;
    var s_mpi: mbed.mbedtls_mpi = undefined;
    mbed.mpi_init(&r_mpi);
    mbed.mpi_init(&s_mpi);
    defer mbed.mpi_free(&r_mpi);
    defer mbed.mpi_free(&s_mpi);

    if (mbed.mpi_read_binary(&r_mpi, r_bytes, scalar_len) != 0)
        return error.InvalidSignature;
    if (mbed.mpi_read_binary(&s_mpi, s_bytes, scalar_len) != 0)
        return error.InvalidSignature;

    if (mbed.ecdsa_verify(&grp, msg_hash, hash_len, &Q, &r_mpi, &s_mpi) != 0)
        return error.SignatureVerificationFailed;
}

fn parseDerSignature(comptime scalar_len: usize, der: []const u8) !struct { r: [scalar_len]u8, s: [scalar_len]u8 } {
    if (der.len < 6) return error.InvalidEncoding;
    if (der[0] != 0x30) return error.InvalidEncoding;

    var pos: usize = 2;
    if (der[1] & 0x80 != 0) pos = 3;

    if (der[pos] != 0x02) return error.InvalidEncoding;
    const r_len = der[pos + 1];
    pos += 2;
    const r_start = if (der[pos] == 0x00) pos + 1 else pos;
    const r_data = der[r_start..][0..@min(scalar_len, der.len - r_start)];
    pos += r_len;

    if (pos >= der.len or der[pos] != 0x02) return error.InvalidEncoding;
    _ = der[pos + 1];
    pos += 2;
    const s_start = if (der[pos] == 0x00) pos + 1 else pos;
    const s_data = der[s_start..][0..@min(scalar_len, der.len - s_start)];

    var result: struct { r: [scalar_len]u8, s: [scalar_len]u8 } = .{
        .r = [_]u8{0} ** scalar_len,
        .s = [_]u8{0} ** scalar_len,
    };
    const r_offset = scalar_len -| r_data.len;
    const s_offset = scalar_len -| s_data.len;
    @memcpy(result.r[r_offset..][0..r_data.len], r_data);
    @memcpy(result.s[s_offset..][0..s_data.len], s_data);
    return result;
}
