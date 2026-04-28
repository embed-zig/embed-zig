const glib = @import("glib");

const Self = @This();

r: u8,
g: u8,
b: u8,

pub fn init(r: u8, g: u8, b: u8) Self {
    return .{ .r = r, .g = g, .b = b };
}

pub fn cmp(self: Self, other: Self) bool {
    return self.r == other.r and self.g == other.g and self.b == other.b;
}

pub fn from565(pixel: u16) Self {
    const red5: u8 = @intCast((pixel >> 11) & 0x1F);
    const green6: u8 = @intCast((pixel >> 5) & 0x3F);
    const blue5: u8 = @intCast(pixel & 0x1F);
    return init(
        (red5 << 3) | (red5 >> 2),
        (green6 << 2) | (green6 >> 4),
        (blue5 << 3) | (blue5 >> 2),
    );
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn cmpComparesAllChannels() !void {
            try grt.std.testing.expect(init(1, 2, 3).cmp(init(1, 2, 3)));
            try grt.std.testing.expect(!init(1, 2, 3).cmp(init(1, 2, 4)));
        }

        fn from565DecodesCommonColors() !void {
            try grt.std.testing.expect(init(0, 0, 0).cmp(from565(0x0000)));
            try grt.std.testing.expect(init(255, 255, 255).cmp(from565(0xFFFF)));
            try grt.std.testing.expect(init(255, 0, 0).cmp(from565(0xF800)));
            try grt.std.testing.expect(init(0, 255, 0).cmp(from565(0x07E0)));
            try grt.std.testing.expect(init(0, 0, 255).cmp(from565(0x001F)));
        }

        fn from565ExpandsPartialChannels() !void {
            const decoded = from565(0x8410);
            try grt.std.testing.expectEqual(@as(u8, 132), decoded.r);
            try grt.std.testing.expectEqual(@as(u8, 130), decoded.g);
            try grt.std.testing.expectEqual(@as(u8, 132), decoded.b);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.cmpComparesAllChannels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.from565DecodesCommonColors() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.from565ExpandsPartialChannels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
