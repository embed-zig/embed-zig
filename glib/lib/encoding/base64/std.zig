const stdz = @import("stdz");

pub const StdEncoding = stdz.base64.standard;
pub const RawStdEncoding = stdz.base64.standard_no_pad;
pub const URLEncoding = stdz.base64.url_safe;
pub const RawURLEncoding = stdz.base64.url_safe_no_pad;

pub fn encodedLen(src_len: usize) usize {
    return StdEncoding.Encoder.calcSize(src_len);
}

pub fn decodedLen(src_len: usize) usize {
    return decodedLenUpperBound(src_len);
}

pub fn encode(allocator: stdz.mem.Allocator, src: []const u8) stdz.mem.Allocator.Error![]u8 {
    return encodeWith(StdEncoding, allocator, src);
}

pub fn decode(allocator: stdz.mem.Allocator, src: []const u8) ![]u8 {
    return decodeWith(StdEncoding, allocator, src);
}

pub fn encodeWith(comptime codec: anytype, allocator: stdz.mem.Allocator, src: []const u8) stdz.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, codec.Encoder.calcSize(src.len));
    _ = codec.Encoder.encode(out, src);
    return out;
}

pub fn decodeWith(comptime codec: anytype, allocator: stdz.mem.Allocator, src: []const u8) ![]u8 {
    const len = try codec.Decoder.calcSizeForSlice(src);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    try codec.Decoder.decode(out, src);
    return out;
}

fn decodedLenUpperBound(src_len: usize) usize {
    return (src_len / 4) * 3 + 3;
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Cases = struct {
        fn encodeStandard(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const out = try encode(allocator, "hello world");
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("aGVsbG8gd29ybGQ=", out);
        }

        fn decodeStandard(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const out = try decode(allocator, "aGVsbG8gd29ybGQ=");
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("hello world", out);
        }

        fn encodeRawUrl(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const out = try encodeWith(RawURLEncoding, allocator, &.{ 0xfb, 0xff });
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("-_8", out);
        }

        fn decodeRejectsInvalidInput(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            try lib.testing.expectError(error.InvalidCharacter, decode(allocator, "****"));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            t.run("encode_standard", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.encodeStandard));
            t.run("decode_standard", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.decodeStandard));
            t.run("encode_raw_url", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.encodeRawUrl));
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
