const esp = @import("esp");

const grt = esp.grt;

const log = grt.std.log.scoped(.blink);

const blink_gpio = 48;
const blink_interval: u64 = @intCast(500 * grt.time.duration.MilliSecond);

extern fn esp_example_blink_init() c_int;
extern fn esp_example_blink_set_rgb(r: u8, g: u8, b: u8) c_int;
extern fn esp_example_blink_clear() c_int;

pub export fn zig_esp_main() void {
    mustOk("esp_example_blink_init", esp_example_blink_init());

    var led_on = false;
    while (true) {
        if (led_on) {
            mustOk("esp_example_blink_set_rgb", esp_example_blink_set_rgb(16, 16, 16));
        } else {
            mustOk("esp_example_blink_clear", esp_example_blink_clear());
        }

        log.info("blink state={s} gpio={d}", .{ if (led_on) "on" else "off", blink_gpio });
        led_on = !led_on;
        grt.std.Thread.sleep(blink_interval);
    }
}

fn mustOk(name: []const u8, rc: c_int) void {
    if (rc == 0) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    @panic("blink platform call failed");
}
