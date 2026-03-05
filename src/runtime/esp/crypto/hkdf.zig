//! HKDF functions - ESP32 mbedTLS implementation via C helper.
//!
//! HKDF-SHA256/384/512 using mbedTLS HMAC-based key derivation.
//! The C helper (hkdf_helper.c) implements extract/expand using
//! mbedTLS HMAC primitives directly.

extern fn hkdf_extract(
    salt: ?[*]const u8,
    salt_len: usize,
    ikm: [*]const u8,
    ikm_len: usize,
    prk: [*]u8,
    hash_len: usize,
) c_int;

extern fn hkdf_expand(
    prk: [*]const u8,
    prk_len: usize,
    info: ?[*]const u8,
    info_len: usize,
    okm: [*]u8,
    okm_len: usize,
) c_int;

fn HkdfImpl(comptime prk_len: usize) type {
    return struct {
        pub const prk_length = prk_len;

        pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
            var prk: [prk_length]u8 = undefined;
            const salt_ptr = if (salt) |s| s.ptr else null;
            const salt_len = if (salt) |s| s.len else 0;
            _ = hkdf_extract(salt_ptr, salt_len, ikm.ptr, ikm.len, &prk, prk_length);
            return prk;
        }

        pub fn expand(prk: *const [prk_length]u8, info: []const u8, out: []u8) void {
            const info_ptr = if (info.len > 0) info.ptr else null;
            _ = hkdf_expand(prk, prk_length, info_ptr, info.len, out.ptr, out.len);
        }
    };
}

pub const HkdfSha256 = HkdfImpl(32);
pub const HkdfSha384 = HkdfImpl(48);
pub const HkdfSha512 = HkdfImpl(64);
