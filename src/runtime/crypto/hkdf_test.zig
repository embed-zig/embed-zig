const std = @import("std");
const module = @import("hkdf.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const from = module.from;
const Sha256 = module.Sha256;
const Sha384 = module.Sha384;
const Sha512 = module.Sha512;


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
