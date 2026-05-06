const glib = @import("glib");
const binding = @import("binding.zig");
const types = @import("types.zig");

const Self = @This();

blue: u8,
green: u8,
red: u8,

pub fn initRgb(red: u8, green: u8, blue: u8) Self {
    return .{
        .blue = blue,
        .green = green,
        .red = red,
    };
}

pub fn fromHex(rgb: u32) Self {
    return initRgb(
        @intCast((rgb >> 16) & 0xff),
        @intCast((rgb >> 8) & 0xff),
        @intCast(rgb & 0xff),
    );
}

pub fn fromHex3(rgb: u32) Self {
    return initRgb(
        @intCast(((rgb >> 4) & 0xf0) | ((rgb >> 8) & 0x0f)),
        @intCast((rgb & 0xf0) | ((rgb & 0xf0) >> 4)),
        @intCast(((rgb & 0x0f) << 4) | (rgb & 0x0f)),
    );
}

pub fn white() Self {
    return initRgb(0xff, 0xff, 0xff);
}

pub fn black() Self {
    return initRgb(0x00, 0x00, 0x00);
}

pub fn lighten(self: Self, amount: types.Opa) Self {
    return mix(white(), self, amount);
}

pub fn darken(self: Self, amount: types.Opa) Self {
    return mix(black(), self, amount);
}

pub fn luminance(self: Self) u8 {
    return @intCast((@as(u32, 77) * self.red + @as(u32, 151) * self.green + @as(u32, 28) * self.blue) >> 8);
}

pub fn eql(self: Self, other: Self) bool {
    return self.red == other.red and self.green == other.green and self.blue == other.blue;
}

pub fn toInt(self: Self) u32 {
    return (@as(u32, self.red) << 16) | (@as(u32, self.green) << 8) | self.blue;
}

pub fn toBinding(self: Self) binding.Color {
    return .{
        .blue = self.blue,
        .green = self.green,
        .red = self.red,
    };
}

pub fn fromBinding(raw: binding.Color) Self {
    return .{
        .blue = raw.blue,
        .green = raw.green,
        .red = raw.red,
    };
}

fn mix(foreground: Self, background: Self, amount: types.Opa) Self {
    return initRgb(
        mixChannel(foreground.red, background.red, amount),
        mixChannel(foreground.green, background.green, amount),
        mixChannel(foreground.blue, background.blue, amount),
    );
}

fn mixChannel(foreground: u8, background: u8, amount: types.Opa) u8 {
    const weight = @as(u32, amount);
    const inverse = 255 - weight;
    return @intCast((@as(u32, foreground) * weight + @as(u32, background) * inverse + 127) / 255);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn helpers_roundtrip_and_transform(_: glib.std.mem.Allocator) !void {
            try grt.std.testing.expectEqual(@sizeOf(binding.Color), @sizeOf(Self));

            const red = Self.initRgb(0xFF, 0x00, 0x00);
            try grt.std.testing.expectEqual(@as(u32, 0xFF0000), red.toInt());
            try grt.std.testing.expect(red.eql(Self.fromHex(0xFF0000)));
            try grt.std.testing.expectEqual(Self.initRgb(0x11, 0x22, 0x33), Self.fromHex3(0x123));

            const white_color = Self.white();
            const black_color = Self.black();
            try grt.std.testing.expectEqual(@as(u32, 0xFFFFFF), white_color.toInt());
            try grt.std.testing.expectEqual(@as(u32, 0x000000), black_color.toInt());
            try grt.std.testing.expect(white_color.luminance() > black_color.luminance());
            try grt.std.testing.expect(red.lighten(types.opa.pct50).luminance() >= red.luminance());
            try grt.std.testing.expect(red.darken(types.opa.pct50).luminance() <= red.luminance());
            try grt.std.testing.expect(red.lighten(types.opa.cover).eql(white_color));
            try grt.std.testing.expect(red.darken(types.opa.cover).eql(black_color));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.helpers_roundtrip_and_transform(allocator) catch |err| {
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
