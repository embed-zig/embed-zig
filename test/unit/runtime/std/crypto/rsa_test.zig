const std = @import("std");
const embed = @import("embed");
const Rsa = embed.runtime.std.Crypto.Rsa;

test "rsa sealed type exposes verify functions" {
    try std.testing.expect(@hasDecl(Rsa, "verifyPKCS1v1_5"));
    try std.testing.expect(@hasDecl(Rsa, "verifyPSS"));
    try std.testing.expect(@hasDecl(Rsa, "parseDer"));
}
