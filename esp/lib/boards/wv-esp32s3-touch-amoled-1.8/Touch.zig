const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("bindings/common.zig");

const Touch = @This();
const Ft5x06 = embed.drivers.Touch.Ft5x06;

const log = esp.grt.std.log.scoped(.wv_touch);
const touch_width: u16 = 448;
const touch_height: u16 = 368;

native_touch: ?Ft5x06 = null,

pub fn init(self: *Touch) !void {
    if (self.native_touch != null) return;

    const i2c = try binding.i2cDevice(Ft5x06.default_address);
    self.native_touch = Ft5x06.init(i2c, .{
        .transform = .{
            .width = touch_width,
            .height = touch_height,
            .swap_xy = true,
            .invert_x = true,
        },
    });
    try self.native_touch.?.open();
    log.info("ft5x06-compatible touch initialized", .{});
}

pub fn handle(self: *Touch) embed.drivers.Touch {
    if (self.native_touch) |*touch| {
        return touch.asTouch();
    }
    @panic("wv touch not initialized");
}
