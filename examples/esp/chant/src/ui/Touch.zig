const embed = @import("embed");
const esp = @import("esp");
const binding = @import("szp_board");

const log = esp.grt.std.log.scoped(.chant_touch);
const Touch = embed.drivers.Touch;
const Ft5x06 = Touch.Ft5x06;

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

var native_touch: ?Ft5x06 = null;

pub fn init() !void {
    if (native_touch != null) return;

    const i2c = try binding.i2cDevice(Ft5x06.default_address);
    native_touch = Ft5x06.init(i2c, .{
        .parameters = szp_parameters,
        .transform = .{
            .width = touch_width,
            .height = touch_height,
            .swap_xy = true,
            .invert_y = true,
        },
    });
    try native_touch.?.open();
    log.info("ft5x06 touch initialized", .{});
}

pub fn driver() Touch {
    if (native_touch) |*touch| {
        return touch.asTouch();
    }
    @panic("chant touch not initialized");
}
