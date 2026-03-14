const std = @import("std");
const module = @import("rsa.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const rsa = module.rsa;

test "rsa wrapper invalid key path" {
    const pk = try rsa.PublicKey.fromBytes(&[_]u8{1}, &[_]u8{1});
    try std.testing.expectError(
        error.CertificatePublicKeyInvalid,
        rsa.PKCS1v1_5Signature.verify(64, [_]u8{0} ** 64, "msg", pk, .sha256),
    );
}
