const std = @import("std");
const module = @import("hmac.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const from = module.from;
const Sha256 = module.Sha256;
const Sha384 = module.Sha384;
const Sha512 = module.Sha512;


test "hmac contract with mock" {
    const MockHmac = struct {
        pub const mac_length = 32;

        pub fn create(out: *[32]u8, _: []const u8, _: []const u8) void {
            out.* = [_]u8{2} ** 32;
        }

        pub fn init(_: []const u8) @This() {
            return .{};
        }

        pub fn update(_: *@This(), _: []const u8) void {}

        pub fn final(_: *@This()) [32]u8 {
            return [_]u8{2} ** 32;
        }
    };

    const H = Sha256(MockHmac);
    _ = H;
}
