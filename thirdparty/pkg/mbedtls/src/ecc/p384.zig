const std = @import("std");

const shared = @import("../shared.zig");

const mbedtls = shared.mbedtls;
const errors = shared.errors;

pub const P384 = struct {
    pub const field_length = 48;
    pub const scalar_length = field_length;
    pub const bits = 384;

    pub const Fe = FieldElement;
    pub const scalar = Scalar;
    pub const basePoint: Point = .{ .sec1 = base_point_sec1 };

    pub const Point = struct {
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

        pub fn mulPublic(self: Self, secret: [scalar_length]u8, endian: std.builtin.Endian) errors.IdentityElementError!SharedPoint {
            if (endian != .big) return error.IdentityElement;
            shared.psa_mutex.lock();
            defer shared.psa_mutex.unlock();
            var key = importSecret(secret, mbedtls.psa.types.usage.derive, mbedtls.psa.types.alg.ecdh) catch return error.IdentityElement;
            defer key.deinit();
            var out: [field_length]u8 = undefined;
            const result = key.rawAgreement(mbedtls.psa.types.alg.ecdh, &self.sec1, &out) catch return error.IdentityElement;
            if (result.len != field_length) return error.IdentityElement;
            return .{ .x = .{ .bytes = out } };
        }
    };

    pub const SharedPoint = struct {
        x: FieldElement,

        pub fn affineCoordinates(self: SharedPoint) AffineCoordinates {
            return .{ .x = self.x };
        }
    };

    pub const AffineCoordinates = struct {
        x: FieldElement,
    };

    pub const FieldElement = struct {
        bytes: [field_length]u8,

        pub fn fromBytes(bytes: [field_length]u8, endian: std.builtin.Endian) FieldElement {
            return .{ .bytes = bytesForEndian(bytes, endian) };
        }

        pub fn toBytes(self: FieldElement, endian: std.builtin.Endian) [field_length]u8 {
            return bytesForEndian(self.bytes, endian);
        }
    };

    pub const Scalar = struct {
        bytes: [scalar_length]u8,

        pub fn fromBytes(bytes: [scalar_length]u8, endian: std.builtin.Endian) errors.NonCanonicalError!Scalar {
            return .{ .bytes = bytesForEndian(bytes, endian) };
        }

        pub fn toBytes(self: Scalar, endian: std.builtin.Endian) [scalar_length]u8 {
            return bytesForEndian(self.bytes, endian);
        }
    };

    const base_point_sec1: [1 + 2 * field_length]u8 = .{
        0x04,
        0xaa,
        0x87,
        0xca,
        0x22,
        0xbe,
        0x8b,
        0x05,
        0x37,
        0x8e,
        0xb1,
        0xc7,
        0x1e,
        0xf3,
        0x20,
        0xad,
        0x74,
        0x6e,
        0x1d,
        0x3b,
        0x62,
        0x8b,
        0xa7,
        0x9b,
        0x98,
        0x59,
        0xf7,
        0x41,
        0xe0,
        0x82,
        0x54,
        0x2a,
        0x38,
        0x55,
        0x02,
        0xf2,
        0x5d,
        0xbf,
        0x55,
        0x29,
        0x6c,
        0x3a,
        0x54,
        0x5e,
        0x38,
        0x72,
        0x76,
        0x0a,
        0xb7,
        0x36,
        0x17,
        0xde,
        0x4a,
        0x96,
        0x26,
        0x2c,
        0x6f,
        0x5d,
        0x9e,
        0x98,
        0xbf,
        0x92,
        0x92,
        0xdc,
        0x29,
        0xf8,
        0xf4,
        0x1d,
        0xbd,
        0x28,
        0x9a,
        0x14,
        0x7c,
        0xe9,
        0xda,
        0x31,
        0x13,
        0xb5,
        0xf0,
        0xb8,
        0xc0,
        0x0a,
        0x60,
        0xb1,
        0xce,
        0x1d,
        0x7e,
        0x81,
        0x9d,
        0x7a,
        0x43,
        0x1d,
        0x7c,
        0x90,
        0xea,
        0x0e,
        0x5f,
    };

    fn bytesForEndian(bytes: [field_length]u8, endian: std.builtin.Endian) [field_length]u8 {
        var out = bytes;
        if (endian == .little) std.mem.reverse(u8, &out);
        return out;
    }

    fn importSecret(secret: [scalar_length]u8, usage: mbedtls.psa.types.Usage, alg: mbedtls.psa.types.Algorithm) mbedtls.Error!mbedtls.psa.key.Key {
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
