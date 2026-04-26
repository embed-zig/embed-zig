//! ledstrip.Color — RGB color helpers for LED strips.

const root = @This();
const glib = @import("glib");

r: u8 = 0,
g: u8 = 0,
b: u8 = 0,

pub const black = root{};
pub const white = root{ .r = 255, .g = 255, .b = 255 };
pub const red = root{ .r = 255 };
pub const green = root{ .g = 255 };
pub const blue = root{ .b = 255 };

pub fn rgb(r: u8, g: u8, b: u8) root {
    return .{ .r = r, .g = g, .b = b };
}

pub fn withBrightness(self: root, brightness: u8) root {
    return .{
        .r = @intCast((@as(u16, self.r) * brightness) / 255),
        .g = @intCast((@as(u16, self.g) * brightness) / 255),
        .b = @intCast((@as(u16, self.b) * brightness) / 255),
    };
}

pub fn lerp(a: root, b: root, t: u8) root {
    const inv_t: u16 = 255 - t;
    return .{
        .r = @intCast((@as(u16, a.r) * inv_t + @as(u16, b.r) * t) / 255),
        .g = @intCast((@as(u16, a.g) * inv_t + @as(u16, b.g) * t) / 255),
        .b = @intCast((@as(u16, a.b) * inv_t + @as(u16, b.b) * t) / 255),
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn rgbAndNamedConstantsMatch() !void {
            try grt.std.testing.expectEqual(red, rgb(255, 0, 0));
            try grt.std.testing.expectEqual(green, rgb(0, 255, 0));
            try grt.std.testing.expectEqual(blue, rgb(0, 0, 255));
            try grt.std.testing.expectEqual(white, rgb(255, 255, 255));
            try grt.std.testing.expectEqual(black, rgb(0, 0, 0));
        }

        fn withBrightnessScalesChannels() !void {
            const color = rgb(255, 128, 64).withBrightness(128);
            try grt.std.testing.expectEqual(root.rgb(128, 64, 32), color);
        }

        fn lerpInterpolatesEndpointsAndMidpoint() !void {
            try grt.std.testing.expectEqual(red, lerp(red, blue, 0));
            try grt.std.testing.expectEqual(blue, lerp(red, blue, 255));

            const mid = lerp(red, blue, 128);
            try grt.std.testing.expectEqual(@as(u8, 127), mid.r);
            try grt.std.testing.expectEqual(@as(u8, 0), mid.g);
            try grt.std.testing.expectEqual(@as(u8, 128), mid.b);
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

            TestCase.rgbAndNamedConstantsMatch() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.withBrightnessScalesChannels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.lerpInterpolatesEndpointsAndMidpoint() catch |err| {
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
