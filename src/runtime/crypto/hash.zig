//! Runtime crypto hash contracts.

/// Generic hash contract validator.
pub fn from(comptime Impl: type, comptime digest_len: usize) type {
    comptime {
        if (!@hasDecl(Impl, "digest_length") or Impl.digest_length != digest_len) {
            @compileError("Hash.digest_length mismatch");
        }

        _ = @as(*const fn () Impl, &Impl.init);
        _ = @as(*const fn (*Impl, []const u8) void, &Impl.update);
        _ = @as(*const fn (*Impl) [digest_len]u8, &Impl.final);
        _ = @as(*const fn ([]const u8, *[digest_len]u8) void, &Impl.hash);
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
