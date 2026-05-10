const embed = @import("embed");
const esp = @import("esp");
const binding = @import("bindings/common.zig");

const Touch = @This();
const Ft5x06 = embed.drivers.Touch.Ft5x06;

const log = esp.grt.std.log.scoped(.szp_touch);
const touch_width: u16 = 320;
const touch_height: u16 = 240;

const szp_parameters = Ft5x06.Parameters{
    .valid_touch_threshold = 70,
    .peak_detect_threshold = 60,
    .focus_threshold = 16,
    .water_threshold = 60,
    .temperature_threshold = 10,
    .touch_difference_threshold = 20,
    .monitor_enter_time = 2,
    .active_period = 12,
    .monitor_period = 40,
};

native_touch: ?Ft5x06 = null,

pub fn init(self: *Touch) !void {
    if (self.native_touch != null) return;

    const i2c = try binding.i2cDevice(Ft5x06.default_address);
    self.native_touch = Ft5x06.init(i2c, .{
        .parameters = szp_parameters,
        .transform = .{
            .width = touch_width,
            .height = touch_height,
            .swap_xy = true,
            .invert_y = true,
        },
    });
    try self.native_touch.?.open();
    log.info("ft5x06 touch initialized", .{});
}

pub fn handle(self: *Touch) embed.drivers.Touch {
    if (self.native_touch) |*touch| {
        return touch.asTouch();
    }
    @panic("szp touch not initialized");
}
