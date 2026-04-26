//! ledstrip.Frame — fixed-size in-memory pixel frame helpers.

const glib = @import("glib");
const Color = @import("Color.zig");

pub fn make(comptime n: usize) type {
    return struct {
        const Self = @This();

        pub const pixel_count = n;

        pixels: [n]Color = [_]Color{Color.black} ** n,

        pub fn solid(color: Color) Self {
            var frame: Self = .{};
            @memset(&frame.pixels, color);
            return frame;
        }

        pub fn gradient(from: Color, to: Color) Self {
            var frame: Self = .{};
            if (n == 0) return frame;
            if (n == 1) {
                frame.pixels[0] = from;
                return frame;
            }

            for (0..n) |i| {
                const t: u8 = @intCast((i * 255) / (n - 1));
                frame.pixels[i] = Color.lerp(from, to, t);
            }
            return frame;
        }

        pub fn rotate(self: Self) Self {
            if (n == 0) return self;

            var frame: Self = .{};
            for (0..n) |i| {
                frame.pixels[i] = self.pixels[(i + 1) % n];
            }
            return frame;
        }

        pub fn flip(self: Self) Self {
            var frame: Self = .{};
            for (0..n) |i| {
                frame.pixels[i] = self.pixels[n - 1 - i];
            }
            return frame;
        }

        pub fn withBrightness(self: Self, brightness: u8) Self {
            var frame: Self = .{};
            for (0..n) |i| {
                frame.pixels[i] = self.pixels[i].withBrightness(brightness);
            }
            return frame;
        }

        pub fn eql(a: Self, b: Self) bool {
            for (0..n) |i| {
                if (a.pixels[i].r != b.pixels[i].r) return false;
                if (a.pixels[i].g != b.pixels[i].g) return false;
                if (a.pixels[i].b != b.pixels[i].b) return false;
            }
            return true;
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn solidFillsAllPixels() !void {
            const F = make(4);
            const frame = F.solid(Color.red);
            for (frame.pixels) |pixel| {
                try grt.std.testing.expectEqual(Color.red, pixel);
            }
        }

        fn gradientPreservesEndpoints() !void {
            const F = make(8);
            const frame = F.gradient(Color.red, Color.blue);
            try grt.std.testing.expectEqual(Color.red, frame.pixels[0]);
            try grt.std.testing.expectEqual(Color.blue, frame.pixels[7]);
        }

        fn rotateShiftsPixelsLeft() !void {
            const F = make(4);
            const frame = F{
                .pixels = .{ Color.red, Color.green, Color.blue, Color.white },
            };
            const rotated = frame.rotate();
            try grt.std.testing.expectEqual(Color.green, rotated.pixels[0]);
            try grt.std.testing.expectEqual(Color.blue, rotated.pixels[1]);
            try grt.std.testing.expectEqual(Color.white, rotated.pixels[2]);
            try grt.std.testing.expectEqual(Color.red, rotated.pixels[3]);
        }

        fn flipReversesPixels() !void {
            const F = make(3);
            const frame = F{
                .pixels = .{ Color.red, Color.green, Color.blue },
            };
            const flipped = frame.flip();
            try grt.std.testing.expectEqual(Color.blue, flipped.pixels[0]);
            try grt.std.testing.expectEqual(Color.green, flipped.pixels[1]);
            try grt.std.testing.expectEqual(Color.red, flipped.pixels[2]);
        }

        fn withBrightnessScalesEntireFrame() !void {
            const F = make(1);
            const frame = F.solid(Color.white).withBrightness(128);
            try grt.std.testing.expectEqual(Color.rgb(128, 128, 128), frame.pixels[0]);
        }

        fn eqlComparesPixels() !void {
            const F = make(2);
            const a = F.solid(Color.red);
            const b = F.solid(Color.red);
            const c = F.solid(Color.green);

            try grt.std.testing.expect(a.eql(b));
            try grt.std.testing.expect(!a.eql(c));
        }

        fn handlesZeroAndOnePixelSizes() !void {
            const F0 = make(0);
            const F1 = make(1);
            const empty = F0{};

            try grt.std.testing.expect(F0.solid(Color.red).eql(empty));
            try grt.std.testing.expect(F0.gradient(Color.red, Color.blue).eql(empty));
            try grt.std.testing.expect(empty.rotate().eql(empty));
            try grt.std.testing.expect(empty.flip().eql(empty));

            const single = F1.gradient(Color.green, Color.blue);
            try grt.std.testing.expectEqual(Color.green, single.pixels[0]);
            try grt.std.testing.expect(single.rotate().eql(single));
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

            TestCase.solidFillsAllPixels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.gradientPreservesEndpoints() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rotateShiftsPixelsLeft() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.flipReversesPixels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.withBrightnessScalesEntireFrame() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.eqlComparesPixels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.handlesZeroAndOnePixelSizes() catch |err| {
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
