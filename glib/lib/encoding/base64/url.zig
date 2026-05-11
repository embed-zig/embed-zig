const base64_std = @import("std.zig");
const stdz = @import("stdz");

pub const Encoding = stdz.base64.url_safe;
pub const RawEncoding = stdz.base64.url_safe_no_pad;

pub fn encodedLen(src_len: usize) usize {
    return Encoding.Encoder.calcSize(src_len);
}

pub fn rawEncodedLen(src_len: usize) usize {
    return RawEncoding.Encoder.calcSize(src_len);
}

pub fn decodeLen(src_len: usize) usize {
    return base64_std.decodedLen(src_len);
}

pub fn encode(allocator: stdz.mem.Allocator, src: []const u8) stdz.mem.Allocator.Error![]u8 {
    return base64_std.encodeWith(Encoding, allocator, src);
}

pub fn decode(allocator: stdz.mem.Allocator, src: []const u8) ![]u8 {
    return base64_std.decodeWith(Encoding, allocator, src);
}

pub fn rawEncode(allocator: stdz.mem.Allocator, src: []const u8) stdz.mem.Allocator.Error![]u8 {
    return base64_std.encodeWith(RawEncoding, allocator, src);
}

pub fn rawDecode(allocator: stdz.mem.Allocator, src: []const u8) ![]u8 {
    return base64_std.decodeWith(RawEncoding, allocator, src);
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Cases = struct {
        fn encodeUrl(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const out = try encode(allocator, &.{ 0xfb, 0xff });
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("-_8=", out);
        }

        fn rawEncodeUrl(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const out = try rawEncode(allocator, &.{ 0xfb, 0xff });
            defer allocator.free(out);

            try lib.testing.expectEqualStrings("-_8", out);
        }

        fn rawDecodeUrl(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const out = try rawDecode(allocator, "-_8");
            defer allocator.free(out);

            try lib.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, out);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            t.run("encode_url", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.encodeUrl));
            t.run("raw_encode_url", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.rawEncodeUrl));
            t.run("raw_decode_url", testing_api.TestRunner.fromFn(lib, 16 * 1024, Cases.rawDecodeUrl));
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
