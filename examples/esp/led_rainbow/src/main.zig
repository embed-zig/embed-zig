const esp = @import("esp");

const grt = esp.grt;

const log = grt.std.log.scoped(.led_rainbow);

const frame_interval: u64 = @intCast(20 * grt.time.duration.MilliSecond);

extern fn esp_example_rainbow_init() c_int;
extern fn esp_example_rainbow_set_rgb(r: u8, g: u8, b: u8) c_int;

pub export fn zig_esp_main() void {
    mustOk("esp_example_rainbow_init", esp_example_rainbow_init());
    log.info("starting rainbow animation on gpio48", .{});

    var hue: u16 = 0;
    while (true) {
        const rgb = wheel(hue);
        mustOk("esp_example_rainbow_set_rgb", esp_example_rainbow_set_rgb(rgb[0], rgb[1], rgb[2]));
        hue +%= 4;
        if (hue >= 1536) hue -= 1536;
        grt.std.Thread.sleep(frame_interval);
    }
}

fn wheel(pos: u16) [3]u8 {
    const segment: u16 = pos / 256;
    const x: u8 = @intCast(pos % 256);
    return switch (segment) {
        0 => .{ 255, x, 0 },
        1 => .{ 255 - x, 255, 0 },
        2 => .{ 0, 255, x },
        3 => .{ 0, 255 - x, 255 },
        4 => .{ x, 0, 255 },
        else => .{ 255, 0, 255 - x },
    };
}

fn mustOk(name: []const u8, rc: c_int) void {
    if (rc == 0) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    @panic("rainbow platform call failed");
}
