const std = @import("std");

pub const binding = @import("binding/root.zig");
pub const c = binding.c;
pub const mbedtls = binding;
pub const errors = std.crypto.errors;

pub var psa_mutex = std.Thread.Mutex{};

pub fn checkMbed(status: c_int) void {
    if (status != 0) @panic("mbedTLS crypto operation failed");
}
