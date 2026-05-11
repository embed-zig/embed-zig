const base58_encoding = @import("encoding.zig");

pub const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
pub const Codec = base58_encoding.Encoding(alphabet);

pub const encodedMaxLen = Codec.encodedMaxLen;
pub const decodedMaxLen = Codec.decodedMaxLen;
pub const encode = Codec.encode;
pub const encodeBuf = Codec.encodeBuf;
pub const decode = Codec.decode;
pub const decodeBuf = Codec.decodeBuf;

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Cases = struct {
        fn encodeVectors(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const empty = try encode(allocator, "");
            defer allocator.free(empty);
            const hello = try encode(allocator, "hello world");
            defer allocator.free(hello);
            const zeros = try encode(allocator, &.{ 0, 0, 1 });
            defer allocator.free(zeros);

            try lib.testing.expectEqualStrings("", empty);
            try lib.testing.expectEqualStrings("StV1DL6CwTryKyV", hello);
            try lib.testing.expectEqualStrings("112", zeros);
        }

        fn encodeBufVectors(_: *testing_api.T, _: lib.mem.Allocator) !void {
            var out: [encodedMaxLen(32)]u8 = undefined;
            var scratch: [encodedMaxLen(32)]u8 = undefined;
            const encoded = try encodeBuf(&.{
                1,  2,  3,  4,  5,  6,  7,  8,
                9,  10, 11, 12, 13, 14, 15, 16,
                17, 18, 19, 20, 21, 22, 23, 24,
                25, 26, 27, 28, 29, 30, 31, 32,
            }, &out, &scratch);

            try lib.testing.expectEqualStrings("4wBqpZM9xaSheZzJSMawUKKwhdpChKbZ5eu5ky4Vigw", encoded);
        }

        fn decodeVectors(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const hello = try decode(allocator, "StV1DL6CwTryKyV");
            defer allocator.free(hello);
            const zeros = try decode(allocator, "112");
            defer allocator.free(zeros);

            try lib.testing.expectEqualStrings("hello world", hello);
            try lib.testing.expectEqualSlices(u8, &.{ 0, 0, 1 }, zeros);
        }

        fn decodeBufVectors(_: *testing_api.T, _: lib.mem.Allocator) !void {
            var out: [32]u8 = undefined;
            var scratch: [decodedMaxLen(44)]u8 = undefined;
            const decoded = try decodeBuf("4wBqpZM9xaSheZzJSMawUKKwhdpChKbZ5eu5ky4Vigw", &out, &scratch);

            try lib.testing.expectEqualSlices(u8, &.{
                1,  2,  3,  4,  5,  6,  7,  8,
                9,  10, 11, 12, 13, 14, 15, 16,
                17, 18, 19, 20, 21, 22, 23, 24,
                25, 26, 27, 28, 29, 30, 31, 32,
            }, decoded);
        }

        fn customAlphabetUsesSameFunctions(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const Custom = base58_encoding.Encoding("0123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz");
            const out = try Custom.encode(allocator, &.{ 0, 0, 1 });
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("001", out);
        }

        fn smallAlphabetUsesSafeMaxLen(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const Custom = base58_encoding.Encoding("01");
            const out = try Custom.encode(allocator, &.{0xff});
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("11111111", out);
        }

        fn decodeRejectsInvalidInput(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            try lib.testing.expectError(error.InvalidCharacter, decode(allocator, "0OIl"));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            t.run("encode_vectors", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.encodeVectors));
            t.run("encode_buf_vectors", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.encodeBufVectors));
            t.run("decode_vectors", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.decodeVectors));
            t.run("decode_buf_vectors", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.decodeBufVectors));
            t.run("custom_alphabet_uses_same_functions", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.customAlphabetUsesSameFunctions));
            t.run("small_alphabet_uses_safe_max_len", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.smallAlphabetUsesSafeMaxLen));
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
