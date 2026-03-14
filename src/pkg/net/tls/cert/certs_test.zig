const module = @import("certs.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const isrg_root_x1 = module.isrg_root_x1;
const amazon_root_ca1 = module.amazon_root_ca1;
const digicert_global_root_g2 = module.digicert_global_root_g2;
const cmn_ca_bundle = module.cmn_ca_bundle;
const mozilla_ca_bundle = module.mozilla_ca_bundle;

test "embedded certs are non-empty PEM" {
    const std = @import("std");
    const certs = [_][]const u8{
        isrg_root_x1,
        amazon_root_ca1,
        digicert_global_root_g2,
        cmn_ca_bundle,
        mozilla_ca_bundle,
    };
    for (certs) |pem| {
        try std.testing.expect(pem.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, pem, "-----BEGIN CERTIFICATE-----") or
            std.mem.startsWith(u8, pem, "##"));
    }
}
