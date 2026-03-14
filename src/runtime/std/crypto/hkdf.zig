const std = @import("std");

pub const HkdfSha256 = struct {
    pub const prk_length = std.crypto.kdf.hkdf.HkdfSha256.prk_length;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return std.crypto.kdf.hkdf.HkdfSha256.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        var out: [len]u8 = undefined;
        std.crypto.kdf.hkdf.HkdfSha256.expand(&out, info, prk.*);
        return out;
    }
};

pub const HkdfSha384 = struct {
    const Inner = std.crypto.kdf.hkdf.Hkdf(std.crypto.auth.hmac.sha2.HmacSha384);
    pub const prk_length = Inner.prk_length;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return Inner.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        var out: [len]u8 = undefined;
        Inner.expand(&out, info, prk.*);
        return out;
    }
};

pub const HkdfSha512 = struct {
    pub const prk_length = std.crypto.kdf.hkdf.HkdfSha512.prk_length;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        return std.crypto.kdf.hkdf.HkdfSha512.extract(salt orelse &[_]u8{}, ikm);
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        var out: [len]u8 = undefined;
        std.crypto.kdf.hkdf.HkdfSha512.expand(&out, info, prk.*);
        return out;
    }
};
