const std = @import("std");
const embed = struct {
    pub const hal = struct {
        pub const led_strip = @import("../../hal/led_strip.zig");
    };
};
const Color = embed.hal.led_strip.Color;
const RemoteHal = @import("../remote_hal.zig").RemoteHal;

pub const max_pixels = 64;

pub const LedStrip = struct {
    pixels: [max_pixels]Color = [_]Color{Color.black} ** max_pixels,
    pixel_count: u32 = 1,
    bus: ?*RemoteHal = null,

    pub fn init() LedStrip {
        return .{};
    }

    pub fn deinit(_: *LedStrip) void {}

    pub fn setPixel(self: *LedStrip, index: u32, color: Color) void {
        if (index >= self.pixel_count) return;
        self.pixels[index] = color;
    }

    pub fn getPixelCount(self: *LedStrip) u32 {
        return self.pixel_count;
    }

    pub fn refresh(self: *LedStrip) void {
        const bus = self.bus orelse return;

        var buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        w.writeAll("{\"dev\":\"led_strip\",\"pixels\":[") catch return;
        for (self.pixels[0..self.pixel_count], 0..) |c, i| {
            if (i > 0) w.writeByte(',') catch return;
            std.fmt.format(w, "{{\"r\":{},\"g\":{},\"b\":{}}}", .{ c.r, c.g, c.b }) catch return;
        }
        w.writeAll("]}") catch return;

        bus.emit(fbs.getWritten());
    }
};

test "websim led_strip satisfies hal contract" {
    const LedStripHal = embed.hal.led_strip.from(struct {
        pub const Driver = LedStrip;
        pub const meta = .{ .id = "led_strip.websim" };
    });

    var drv = LedStrip.init();
    var strip = LedStripHal.init(&drv);

    try std.testing.expectEqual(@as(u32, 1), strip.getPixelCount());

    strip.setPixel(0, Color.red);
    try std.testing.expectEqual(Color.red, drv.pixels[0]);
}
