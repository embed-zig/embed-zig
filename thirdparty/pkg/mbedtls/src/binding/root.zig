pub const c = @import("c.zig").c;

pub const errors = @import("error.zig");
pub const features = @import("features.zig");
pub const version = @import("version.zig");
pub const psa = @import("psa.zig");

pub const Error = errors.Error;

pub fn versionNumber() u32 {
    return version.mbedtlsNumber();
}

pub fn versionStringFull() []const u8 {
    return version.mbedtlsStringFull();
}
