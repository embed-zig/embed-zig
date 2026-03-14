//! Runtime crypto HMAC contracts.

/// Generic HMAC contract validator.
pub fn from(comptime Impl: type, comptime mac_len: usize) type {
    comptime {
        if (!@hasDecl(Impl, "mac_length") or Impl.mac_length != mac_len) {
            @compileError("HMAC.mac_length mismatch");
        }

        _ = @as(*const fn (*[mac_len]u8, []const u8, []const u8) void, &Impl.create);
        _ = @as(*const fn ([]const u8) Impl, &Impl.init);
        _ = @as(*const fn (*Impl, []const u8) void, &Impl.update);
        _ = @as(*const fn (*Impl) [mac_len]u8, &Impl.final);
    }
    return Impl;
}

pub fn Sha256(comptime Impl: type) type {
    return from(Impl, 32);
}

pub fn Sha384(comptime Impl: type) type {
    return from(Impl, 48);
}

pub fn Sha512(comptime Impl: type) type {
    return from(Impl, 64);
}
