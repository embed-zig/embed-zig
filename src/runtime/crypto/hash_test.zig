const std = @import("std");
const module = @import("hash.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const from = module.from;
const Sha256 = module.Sha256;
const Sha384 = module.Sha384;
const Sha512 = module.Sha512;


test "hash contract with mock" {
    const MockHash = struct {
        pub const digest_length = 32;

        pub fn init() @This() {
            return .{};
        }

        pub fn update(_: *@This(), _: []const u8) void {}

        pub fn final(_: *@This()) [32]u8 {
            return [_]u8{0} ** 32;
        }

        pub fn hash(_: []const u8, out: *[32]u8) void {
            out.* = [_]u8{1} ** 32;
        }
    };

    const H = Sha256(MockHash);
    _ = H;
}
