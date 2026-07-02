const bk = @import("bk");
const build_config = @import("build_config");

const armino = bk.armino;
const grt = bk.ap.grt;
const log = grt.std.log.scoped(.bk_gpio_smoke_ap);

const smoke_pin: u32 = 26;

export fn zig_ap_main() c_int {
    earlyLog("[BK GPIO AP] zig_ap_main entered\r\n");
    armino.system.init() catch |err| {
        earlyLog("[BK GPIO AP] armino init failed\r\n");
        log.err("armino init failed: {}", .{err});
        return 1;
    };

    runSmoke() catch |err| {
        earlyLog("[BK GPIO AP] smoke failed\r\n");
        log.err("gpio smoke failed: {}", .{err});
        return 1;
    };
    return 0;
}

fn runSmoke() !void {
    log.info("main entered board={s} pin={}", .{ build_config.Board.name, smoke_pin });

    var pin = bk.embed.gpio.Pin.init(.{ .pin = smoke_pin });
    const gpio = pin.handle();
    try gpio.setDirection(.output);

    var high = false;
    while (true) {
        high = !high;
        try gpio.write(if (high) .high else .low);
        log.info("pin={} level={s}", .{ smoke_pin, @tagName(try gpio.read()) });

        gpio.configureInterrupt(.both) catch |err| {
            if (err == error.Unsupported) {
                log.info("gpio irq unsupported on BK adapter; poll/read smoke continues", .{});
            } else {
                return err;
            }
        };
        grt.time.sleep(500 * grt.time.duration.MilliSecond);
    }
}

fn earlyLog(message: [:0]const u8) void {
    armino.system.emergencyUartWriteString(0, message);
}
