pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/mbedtls",
    .labels = &.{"unit"},
};

fn sourceFile() []const u8 {
    return @src().file;
}

const mbedtls = @import("mbedtls");

test "thirdparty/mbedtls/unit" {
    const std = @import("std");
    const crypto = mbedtls.crypto;

    var digest: [crypto.Sha256.digest_length]u8 = undefined;
    crypto.Sha256.hash("abc", &digest, .{});
    try std.testing.expectEqualSlices(u8, &.{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    }, &digest);

    var mac: [crypto.HmacSha256.mac_length]u8 = undefined;
    crypto.HmacSha256.create(&mac, "message", "key");
    try std.testing.expect(!std.mem.allEqual(u8, &mac, 0));

    const prk = crypto.HkdfSha256.extract("salt", "ikm");
    var okm: [42]u8 = undefined;
    crypto.HkdfSha256.expand(&okm, "info", prk);
    try std.testing.expect(!std.mem.allEqual(u8, &okm, 0));

    var key: [crypto.Aes128Gcm.key_length]u8 = undefined;
    var nonce: [crypto.Aes128Gcm.nonce_length]u8 = undefined;
    @memset(&key, 0x42);
    @memset(&nonce, 0x24);

    const plaintext = "mbedtls aead smoke";
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [crypto.Aes128Gcm.tag_length]u8 = undefined;
    crypto.Aes128Gcm.encrypt(&ciphertext, &tag, plaintext, "aad", nonce, key);

    var decrypted: [plaintext.len]u8 = undefined;
    try crypto.Aes128Gcm.decrypt(&decrypted, &ciphertext, tag, "aad", nonce, key);
    try std.testing.expectEqualSlices(u8, plaintext, &decrypted);
}
