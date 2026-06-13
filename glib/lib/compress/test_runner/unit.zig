const testing_api = @import("testing");

pub fn make(comptime std: type, comptime compress: type) testing_api.TestRunner {
    const Runner = struct {
        const testing = std.testing;
        const input = "hello compress";
        const raw = [_]u8{ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0x06, 0x00 };
        const zlib = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0x06, 0x00, 0x29, 0x38, 0x05, 0xa1 };
        const gzip = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x13, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0x06, 0x00, 0xcd, 0x75, 0x7e, 0x84, 0x0e, 0x00, 0x00, 0x00 };

        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;

            expectInflate(.raw, &raw) catch |err| return fail(t, err);
            expectInflate(.zlib, &zlib) catch |err| return fail(t, err);
            expectInflate(.gzip, &gzip) catch |err| return fail(t, err);
            expectOutputTooSmall() catch |err| return fail(t, err);
            expectInflateAlloc(allocator) catch |err| return fail(t, err);
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn expectInflate(container: compress.Container, compressed: []const u8) !void {
            var out: [input.len]u8 = undefined;
            const len = try compress.inflate(container, compressed, &out);
            try testing.expectEqual(input.len, len);
            try testing.expectEqualSlices(u8, input, out[0..len]);
        }

        fn expectOutputTooSmall() !void {
            var out: [input.len - 1]u8 = undefined;
            try testing.expectError(error.OutputTooSmall, compress.inflate(.raw, &raw, &out));
        }

        fn expectInflateAlloc(allocator: std.mem.Allocator) !void {
            const out = try compress.inflateAlloc(allocator, .zlib, &zlib, input.len);
            defer allocator.free(out);

            try testing.expectEqualSlices(u8, input, out);
        }

        fn fail(t: *testing_api.T, err: anyerror) bool {
            t.logFatal(@errorName(err));
            return false;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
