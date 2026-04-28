const binding = @import("mbedtls/src/binding/root.zig");

pub const errors = binding.errors;
pub const crypto = @import("mbedtls/src/crypto.zig");
pub const Error = binding.Error;

pub const versionNumber = binding.versionNumber;
pub const versionStringFull = binding.versionStringFull;
