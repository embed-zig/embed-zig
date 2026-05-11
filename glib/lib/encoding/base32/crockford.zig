const base32_encoding = @import("encoding.zig");

pub const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
pub const Codec = base32_encoding.Encoding(.{
    .alphabet = alphabet,
    .case_insensitive = true,
    .ignore_hyphen = true,
    .crockford_aliases = true,
});

pub const encodedLen = Codec.encodedLen;
pub const encode = Codec.encode;
pub const encodeBuf = Codec.encodeBuf;
pub const decode = Codec.decode;
pub const decodeBuf = Codec.decodeBuf;

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Cases = struct {
        fn encodeHello(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const out = try encode(allocator, "hello");
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("D1JPRV3F", out);
        }

        fn decodeHello(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const out = try decode(allocator, "d1jprv-3f");
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("hello", out);
        }

        fn decodeBufVector(_: *testing_api.T, _: lib.mem.Allocator) !void {
            var out: [32]u8 = undefined;
            const decoded = try decodeBuf("041061050R3GG28A1C60T3GF208H44RM2MB1E60S38DHR78Y3WG0", &out);

            try lib.testing.expectEqualSlices(u8, &.{
                1,  2,  3,  4,  5,  6,  7,  8,
                9,  10, 11, 12, 13, 14, 15, 16,
                17, 18, 19, 20, 21, 22, 23, 24,
                25, 26, 27, 28, 29, 30, 31, 32,
            }, decoded);
        }

        fn decodeAliases(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const zero = try decode(allocator, "O");
            defer allocator.free(zero);
            const one = try decode(allocator, "L0");
            defer allocator.free(one);

            try lib.testing.expectEqual(@as(usize, 0), zero.len);
            try lib.testing.expectEqualSlices(u8, &.{0x08}, one);
        }

        fn customAlphabetUsesSameFunctions(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const Custom = base32_encoding.Encoding(.{ .alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567" });
            const out = try Custom.encode(allocator, "hello");
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("NBSWY3DP", out);
        }

        fn decodeRejectsInvalidInput(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            try lib.testing.expectError(error.InvalidCharacter, decode(allocator, "U"));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            t.run("encode_hello", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.encodeHello));
            t.run("decode_hello", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.decodeHello));
            t.run("decode_buf_vector", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.decodeBufVector));
            t.run("decode_aliases", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.decodeAliases));
            t.run("custom_alphabet_uses_same_functions", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.customAlphabetUsesSameFunctions));
            t.run("decode_rejects_invalid_input", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.decodeRejectsInvalidInput));
            _ = allocator;
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
