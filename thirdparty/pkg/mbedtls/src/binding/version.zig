const std = @import("std");

const c = @import("c.zig").c;

pub fn mbedtlsNumber() u32 {
    return c.mbedtls_version_get_number();
}

pub fn mbedtlsStringFull() []const u8 {
    return std.mem.span(c.mbedtls_version_get_string_full());
}

pub fn tfPsaCryptoNumber() u32 {
    return c.tf_psa_crypto_version_get_number();
}

pub fn tfPsaCryptoStringFull() []const u8 {
    return std.mem.span(c.tf_psa_crypto_version_get_string_full());
}
