const std = @import("std");
const testing = std.testing;
const module = @import("sha1.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const digest_length = module.digest_length;
const block_length = module.block_length;
const init = module.init;
const update = module.update;
const final = module.final;
const hash = module.hash;
const Self = test_exports.Self;
const processBlock = test_exports.processBlock;
const rotl = test_exports.rotl;

test "SHA1 empty string" {
    const digest = hash("");
    const expected = [_]u8{
        0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d, 0x32, 0x55,
        0xbf, 0xef, 0x95, 0x60, 0x18, 0x90, 0xaf, 0xd8, 0x07, 0x09,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "SHA1 abc" {
    const digest = hash("abc");
    const expected = [_]u8{
        0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e,
        0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "SHA1 WebSocket accept key" {
    const input = "dGhlIHNhbXBsZSBub25jZQ==" ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const digest = hash(input);
    const expected = [_]u8{
        0xb3, 0x7a, 0x4f, 0x2c, 0xc0, 0x62, 0x4f, 0x16, 0x90, 0xf6,
        0x46, 0x06, 0xcf, 0x38, 0x59, 0x45, 0xb2, 0xbe, 0xc4, 0xea,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "SHA1 longer than one block" {
    const input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    const digest = hash(input);
    const expected = [_]u8{
        0x84, 0x98, 0x3e, 0x44, 0x1c, 0x3b, 0xd2, 0x6e, 0xba, 0xae,
        0x4a, 0xa1, 0xf9, 0x51, 0x29, 0xe5, 0xe5, 0x46, 0x70, 0xf1,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "SHA1 incremental update matches single-shot" {
    const data = "The quick brown fox jumps over the lazy dog";
    const single = hash(data);

    var h = init();
    h.update(data[0..10]);
    h.update(data[10..20]);
    h.update(data[20..]);
    const incremental = h.final();

    try std.testing.expectEqualSlices(u8, &single, &incremental);
}
