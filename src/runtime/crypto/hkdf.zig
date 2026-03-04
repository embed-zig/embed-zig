/// Generic HKDF contract validator.
///
/// Required:
/// - `prk_length: usize`
/// - `extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8`
/// - `expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8`
pub fn from(comptime Impl: type, comptime prk_len: usize) type {
    comptime {
        if (!@hasDecl(Impl, "prk_length") or Impl.prk_length != prk_len) {
            @compileError("HKDF.prk_length mismatch");
        }

        _ = @as(*const fn (?[]const u8, []const u8) [prk_len]u8, &Impl.extract);

        if (!@hasDecl(Impl, "expand")) {
            @compileError("HKDF missing expand");
        }
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

test "hkdf contract with mock" {
    const MockHkdf = struct {
        pub const prk_length = 32;

        pub fn extract(_: ?[]const u8, _: []const u8) [32]u8 {
            return [_]u8{3} ** 32;
        }

        pub fn expand(_: *const [32]u8, _: []const u8, comptime len: usize) [len]u8 {
            return [_]u8{0x33} ** len;
        }
    };

    const H = Sha256(MockHkdf);
    _ = H;
}
