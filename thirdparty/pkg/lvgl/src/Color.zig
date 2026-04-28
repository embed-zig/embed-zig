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
    return fromBinding(binding.lv_color_hex(rgb));
}

pub fn fromHex3(rgb: u32) Self {
    return fromBinding(binding.lv_color_hex3(rgb));
}

pub fn white() Self {
    return fromBinding(binding.lv_color_white());
}

pub fn black() Self {
    return fromBinding(binding.lv_color_black());
}

pub fn lighten(self: Self, amount: types.Opa) Self {
    return fromBinding(binding.lv_color_lighten(self.toBinding(), amount));
}

pub fn darken(self: Self, amount: types.Opa) Self {
    return fromBinding(binding.lv_color_darken(self.toBinding(), amount));
}

pub fn luminance(self: Self) u8 {
    return binding.lv_color_luminance(self.toBinding());
}

pub fn eql(self: Self, other: Self) bool {
    return binding.lv_color_eq(self.toBinding(), other.toBinding());
}

pub fn toInt(self: Self) u32 {
    return binding.lv_color_to_int(self.toBinding());
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn helpers_roundtrip_and_transform(_: glib.std.mem.Allocator) !void {
            try grt.std.testing.expectEqual(@sizeOf(binding.Color), @sizeOf(Self));

            const red = Self.initRgb(0xFF, 0x00, 0x00);
            try grt.std.testing.expectEqual(@as(u32, 0xFF0000), red.toInt());
            try grt.std.testing.expect(red.eql(Self.fromHex(0xFF0000)));

            const white_color = Self.white();
            const black_color = Self.black();
            try grt.std.testing.expect(white_color.luminance() > black_color.luminance());
            try grt.std.testing.expect(red.lighten(types.opa.pct50).luminance() >= red.luminance());
            try grt.std.testing.expect(red.darken(types.opa.pct50).luminance() <= red.luminance());
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
