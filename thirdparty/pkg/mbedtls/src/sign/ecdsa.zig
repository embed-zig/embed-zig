const std = @import("std");

const sha2 = @import("../hash/sha2.zig");
const shared = @import("../shared.zig");
const random_mod = @import("../random.zig");

const mbedtls = shared.mbedtls;
const errors = shared.errors;
const random = random_mod.random;

pub const EcdsaP256Sha256 = EcdsaImpl(32, sha2.Sha256, mbedtls.psa.types.alg.sha256, 256);
pub const EcdsaP384Sha384 = EcdsaImpl(48, sha2.Sha384, mbedtls.psa.types.alg.sha384, 384);

pub fn EcdsaImpl(
    comptime field_length: usize,
    comptime Hash: type,
    comptime hash_alg: mbedtls.psa.types.Algorithm,
    comptime bits: usize,
) type {
    return struct {
        pub const noise_length = field_length;

        pub const SecretKey = struct {
            pub const encoded_length = field_length;

            bytes: [encoded_length]u8,

            pub fn fromBytes(bytes: [encoded_length]u8) errors.IdentityElementError!SecretKey {
                shared.psa_mutex.lock();
                defer shared.psa_mutex.unlock();
                var key = importSecret(bytes, mbedtls.psa.types.usage.sign_hash) catch return error.IdentityElement;
                defer key.deinit();
                return .{ .bytes = bytes };
            }

            pub fn toBytes(sk: SecretKey) [encoded_length]u8 {
                return sk.bytes;
            }
        };

        pub const PublicKey = struct {
            pub const compressed_sec1_encoded_length = 1 + field_length;
            pub const uncompressed_sec1_encoded_length = 1 + 2 * field_length;

            p: CurvePoint,

            pub fn fromSec1(sec1: []const u8) errors.EncodingError!PublicKey {
                return .{ .p = try CurvePoint.fromSec1(sec1) };
            }

            pub fn toCompressedSec1(pk: PublicKey) [compressed_sec1_encoded_length]u8 {
                return pk.p.toCompressedSec1();
            }

            pub fn toUncompressedSec1(pk: PublicKey) [uncompressed_sec1_encoded_length]u8 {
                return pk.p.toUncompressedSec1();
            }
        };

        pub const Signature = struct {
            pub const encoded_length = field_length * 2;
            pub const der_encoded_length_max = encoded_length + 2 + 2 * 3;

            r: [field_length]u8,
            s: [field_length]u8,

            pub const VerifyError = Verifier.InitError || Verifier.VerifyError;

            pub fn verifier(sig: Signature, public_key: PublicKey) Verifier.InitError!Verifier {
                return Verifier.init(sig, public_key);
            }

            pub fn verify(sig: Signature, msg: []const u8, public_key: PublicKey) VerifyError!void {
                var st = try sig.verifier(public_key);
                st.update(msg);
                try st.verify();
            }

            pub fn verifyPrehashed(sig: Signature, msg_hash: [Hash.digest_length]u8, public_key: PublicKey) VerifyError!void {
                var st = try sig.verifier(public_key);
                try st.verifyPrehashed(msg_hash);
            }

            pub fn toBytes(sig: Signature) [encoded_length]u8 {
                var bytes: [encoded_length]u8 = undefined;
                @memcpy(bytes[0..field_length], &sig.r);
                @memcpy(bytes[field_length..encoded_length], &sig.s);
                return bytes;
            }

            pub fn fromBytes(bytes: [encoded_length]u8) Signature {
                return .{
                    .r = bytes[0..field_length].*,
                    .s = bytes[field_length..encoded_length].*,
                };
            }

            pub fn toDer(sig: Signature, buf: *[der_encoded_length_max]u8) []u8 {
                var fb = std.io.fixedBufferStream(buf);
                const w = fb.writer();
                const r_len = @as(u8, @intCast(sig.r.len + (sig.r[0] >> 7)));
                const s_len = @as(u8, @intCast(sig.s.len + (sig.s[0] >> 7)));
                const seq_len = @as(u8, @intCast(2 + r_len + 2 + s_len));
                w.writeAll(&.{ 0x30, seq_len }) catch unreachable;
                w.writeAll(&.{ 0x02, r_len }) catch unreachable;
                if (sig.r[0] >> 7 != 0) w.writeByte(0x00) catch unreachable;
                w.writeAll(&sig.r) catch unreachable;
                w.writeAll(&.{ 0x02, s_len }) catch unreachable;
                if (sig.s[0] >> 7 != 0) w.writeByte(0x00) catch unreachable;
                w.writeAll(&sig.s) catch unreachable;
                return fb.getWritten();
            }

            pub fn fromDer(der: []const u8) errors.EncodingError!Signature {
                var sig: Signature = std.mem.zeroes(Signature);
                var fb = std.io.fixedBufferStream(der);
                const reader = fb.reader();
                var buf: [2]u8 = undefined;
                reader.readNoEof(&buf) catch return error.InvalidEncoding;
                if (buf[0] != 0x30 or @as(usize, buf[1]) + 2 != der.len) return error.InvalidEncoding;
                try readDerInt(&sig.r, reader);
                try readDerInt(&sig.s, reader);
                if (fb.getPos() catch unreachable != der.len) return error.InvalidEncoding;
                return sig;
            }

            fn readDerInt(out: []u8, reader: anytype) errors.EncodingError!void {
                var buf: [2]u8 = undefined;
                reader.readNoEof(&buf) catch return error.InvalidEncoding;
                if (buf[0] != 0x02) return error.InvalidEncoding;
                var expected_len = @as(usize, buf[1]);
                if (expected_len == 0 or expected_len > 1 + out.len) return error.InvalidEncoding;
                var has_top_bit = false;
                if (expected_len == 1 + out.len) {
                    if ((reader.readByte() catch return error.InvalidEncoding) != 0) return error.InvalidEncoding;
                    expected_len -= 1;
                    has_top_bit = true;
                }
                const out_slice = out[out.len - expected_len ..];
                reader.readNoEof(out_slice) catch return error.InvalidEncoding;
                if (@intFromBool(has_top_bit) != out[0] >> 7) return error.InvalidEncoding;
            }
        };

        pub const Signer = struct {
            h: Hash,
            secret_key: SecretKey,

            fn init(secret_key: SecretKey, _: ?[noise_length]u8) !Signer {
                return .{
                    .h = Hash.init(.{}),
                    .secret_key = secret_key,
                };
            }

            pub fn update(self: *Signer, data: []const u8) void {
                self.h.update(data);
            }

            fn finalizePrehashed(self: *Signer, msg_hash: [Hash.digest_length]u8) (errors.IdentityElementError || errors.NonCanonicalError)!Signature {
                shared.psa_mutex.lock();
                defer shared.psa_mutex.unlock();
                var key = importSecret(self.secret_key.bytes, mbedtls.psa.types.usage.sign_hash) catch return error.IdentityElement;
                defer key.deinit();
                var sig: [Signature.encoded_length]u8 = undefined;
                const result = key.signHash(mbedtls.psa.types.alg.ecdsa(hash_alg), &msg_hash, &sig) catch return error.IdentityElement;
                if (result.len != Signature.encoded_length) {
                    return Signature.fromDer(result) catch return error.IdentityElement;
                }
                return Signature.fromBytes(sig);
            }

            pub fn finalize(self: *Signer) (errors.IdentityElementError || errors.NonCanonicalError)!Signature {
                var h: [Hash.digest_length]u8 = undefined;
                self.h.final(&h);
                return self.finalizePrehashed(h);
            }
        };

        pub const Verifier = struct {
            h: Hash,
            sig: Signature,
            public_key: PublicKey,

            pub const InitError = errors.IdentityElementError || errors.NonCanonicalError;
            pub const VerifyError = errors.SignatureVerificationError;

            fn init(sig: Signature, public_key: PublicKey) InitError!Verifier {
                return .{
                    .h = Hash.init(.{}),
                    .sig = sig,
                    .public_key = public_key,
                };
            }

            pub fn update(self: *Verifier, data: []const u8) void {
                self.h.update(data);
            }

            fn verifyPrehashed(self: *Verifier, msg_hash: [Hash.digest_length]u8) VerifyError!void {
                shared.psa_mutex.lock();
                defer shared.psa_mutex.unlock();
                var key = importPublic(self.public_key.p.sec1[0..], mbedtls.psa.types.usage.verify_hash, mbedtls.psa.types.alg.ecdsa(hash_alg)) catch return error.SignatureVerificationFailed;
                defer key.deinit();
                const sig = self.sig.toBytes();
                key.verifyHash(mbedtls.psa.types.alg.ecdsa(hash_alg), &msg_hash, &sig) catch return error.SignatureVerificationFailed;
            }

            pub fn verify(self: *Verifier) VerifyError!void {
                var h: [Hash.digest_length]u8 = undefined;
                self.h.final(&h);
                return self.verifyPrehashed(h);
            }
        };

        pub const KeyPair = struct {
            pub const seed_length = noise_length;

            public_key: PublicKey,
            secret_key: SecretKey,

            pub fn generateDeterministic(seed: [seed_length]u8) errors.IdentityElementError!KeyPair {
                return fromSecretKey(try SecretKey.fromBytes(seed));
            }

            pub fn generate() KeyPair {
                while (true) {
                    var seed: [seed_length]u8 = undefined;
                    random.bytes(&seed);
                    return generateDeterministic(seed) catch continue;
                }
            }

            pub fn fromSecretKey(secret_key: SecretKey) errors.IdentityElementError!KeyPair {
                shared.psa_mutex.lock();
                defer shared.psa_mutex.unlock();
                var key = importSecret(secret_key.bytes, mbedtls.psa.types.usage.export_key) catch return error.IdentityElement;
                defer key.deinit();
                var public_buf: [CurvePoint.uncompressed_sec1_encoded_length]u8 = undefined;
                const public = key.exportPublic(&public_buf) catch return error.IdentityElement;
                return .{
                    .secret_key = secret_key,
                    .public_key = .{ .p = CurvePoint.fromGeneratedPublic(public) catch return error.IdentityElement },
                };
            }

            pub fn sign(key_pair: KeyPair, msg: []const u8, noise: ?[noise_length]u8) (errors.IdentityElementError || errors.NonCanonicalError)!Signature {
                var st = try key_pair.signer(noise);
                st.update(msg);
                return st.finalize();
            }

            pub fn signPrehashed(key_pair: KeyPair, msg_hash: [Hash.digest_length]u8, noise: ?[noise_length]u8) (errors.IdentityElementError || errors.NonCanonicalError)!Signature {
                var st = try key_pair.signer(noise);
                return st.finalizePrehashed(msg_hash);
            }

            pub fn signer(key_pair: KeyPair, noise: ?[noise_length]u8) !Signer {
                return Signer.init(key_pair.secret_key, noise);
            }
        };

        const CurvePoint = EcdhPoint(field_length, bits);

        fn importSecret(secret: [field_length]u8, usage: mbedtls.psa.types.Usage) mbedtls.Error!mbedtls.psa.key.Key {
            var attrs = mbedtls.psa.key.KeyAttributes.init();
            defer attrs.deinit();
            attrs.setType(mbedtls.psa.types.key_type.eccKeyPair(mbedtls.psa.types.ecc_family.secp_r1));
            attrs.setBits(bits);
            attrs.setUsage(usage | mbedtls.psa.types.usage.export_key);
            attrs.setAlgorithm(mbedtls.psa.types.alg.ecdsa(hash_alg));
            return mbedtls.psa.key.Key.import(&attrs, &secret);
        }

        fn importPublic(sec1: []const u8, usage: mbedtls.psa.types.Usage, alg: mbedtls.psa.types.Algorithm) mbedtls.Error!mbedtls.psa.key.Key {
            var attrs = mbedtls.psa.key.KeyAttributes.init();
            defer attrs.deinit();
            attrs.setType(mbedtls.psa.types.key_type.eccPublicKey(mbedtls.psa.types.ecc_family.secp_r1));
            attrs.setBits(bits);
            attrs.setUsage(usage);
            attrs.setAlgorithm(alg);
            return mbedtls.psa.key.Key.import(&attrs, sec1);
        }
    };
}

fn EcdhPoint(comptime field_length: usize, comptime bits: usize) type {
    return struct {
        pub const compressed_sec1_encoded_length = 1 + field_length;
        pub const uncompressed_sec1_encoded_length = 1 + 2 * field_length;

        sec1: [uncompressed_sec1_encoded_length]u8,

        const Self = @This();

        pub fn fromSec1(sec1: []const u8) errors.EncodingError!Self {
            if (sec1.len != uncompressed_sec1_encoded_length or sec1[0] != 0x04) return error.InvalidEncoding;
            shared.psa_mutex.lock();
            defer shared.psa_mutex.unlock();
            var key = importPublic(sec1, mbedtls.psa.types.usage.derive, mbedtls.psa.types.alg.ecdh) catch return error.InvalidEncoding;
            defer key.deinit();
            return try fromGeneratedPublic(sec1);
        }

        fn fromGeneratedPublic(sec1: []const u8) errors.EncodingError!Self {
            if (sec1.len != uncompressed_sec1_encoded_length or sec1[0] != 0x04) return error.InvalidEncoding;
            return .{ .sec1 = sec1[0..uncompressed_sec1_encoded_length].* };
        }

        pub fn toUncompressedSec1(self: Self) [uncompressed_sec1_encoded_length]u8 {
            return self.sec1;
        }

        pub fn toCompressedSec1(self: Self) [compressed_sec1_encoded_length]u8 {
            var out: [compressed_sec1_encoded_length]u8 = undefined;
            out[0] = 0x02 | (self.sec1[self.sec1.len - 1] & 1);
            @memcpy(out[1..], self.sec1[1..][0..field_length]);
            return out;
        }

        pub fn mulPublic(self: Self, scalar: [field_length]u8, endian: std.builtin.Endian) errors.IdentityElementError!SharedPoint {
            if (endian != .big) return error.IdentityElement;
            shared.psa_mutex.lock();
            defer shared.psa_mutex.unlock();
            var key = importSecret(scalar, mbedtls.psa.types.usage.derive, mbedtls.psa.types.alg.ecdh) catch return error.IdentityElement;
            defer key.deinit();
            var out: [field_length]u8 = undefined;
            const result = key.rawAgreement(mbedtls.psa.types.alg.ecdh, &self.sec1, &out) catch return error.IdentityElement;
            if (result.len != field_length) return error.IdentityElement;
            return .{ .x = .{ .bytes = out } };
        }

        const SharedPoint = struct {
            x: FieldElement,

            pub fn affineCoordinates(self: SharedPoint) AffineCoordinates {
                return .{ .x = self.x };
            }
        };

        const AffineCoordinates = struct {
            x: FieldElement,
        };

        const FieldElement = struct {
            bytes: [field_length]u8,

            pub fn toBytes(self: FieldElement, endian: std.builtin.Endian) [field_length]u8 {
                if (endian != .big) @panic("mbedTLS ECDH shared secret only supports big-endian output");
                return self.bytes;
            }
        };

        fn importSecret(secret: [field_length]u8, usage: mbedtls.psa.types.Usage, alg: mbedtls.psa.types.Algorithm) mbedtls.Error!mbedtls.psa.key.Key {
            var attrs = mbedtls.psa.key.KeyAttributes.init();
            defer attrs.deinit();
            attrs.setType(mbedtls.psa.types.key_type.eccKeyPair(mbedtls.psa.types.ecc_family.secp_r1));
            attrs.setBits(bits);
            attrs.setUsage(usage);
            attrs.setAlgorithm(alg);
            return mbedtls.psa.key.Key.import(&attrs, &secret);
        }

        fn importPublic(sec1: []const u8, usage: mbedtls.psa.types.Usage, alg: mbedtls.psa.types.Algorithm) mbedtls.Error!mbedtls.psa.key.Key {
            var attrs = mbedtls.psa.key.KeyAttributes.init();
            defer attrs.deinit();
            attrs.setType(mbedtls.psa.types.key_type.eccPublicKey(mbedtls.psa.types.ecc_family.secp_r1));
            attrs.setBits(bits);
            attrs.setUsage(usage);
            attrs.setAlgorithm(alg);
            return mbedtls.psa.key.Key.import(&attrs, sec1);
        }
    };
}
