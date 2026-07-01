const embed = @import("embed");
const esp = @import("esp");

const grt = esp.grt;
const log = grt.std.log.scoped(.gpio_smoke);

const output_pin: c_int = 4;
const input_pin: c_int = 0;

const EventSink = struct {
    count: usize = 0,

    fn emit(ctx: *const anyopaque, event: embed.drivers.Gpio.Event) void {
        const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
        self.count += 1;
        log.info("gpio event edge={s} level={s} count={}", .{
            @tagName(event.edge),
            @tagName(event.level),
            self.count,
        });
    }
};

pub export fn zig_esp_main() void {
    run() catch |err| {
        log.err("gpio smoke failed: {s}", .{@errorName(err)});
        @panic("gpio smoke failed");
    };
}

fn run() !void {
    var output = esp.embed.gpio.Pin.init(.{ .pin = output_pin });
    var sink = EventSink{};
    const output_gpio = output.handle();
    try output_gpio.setDirection(.output);
    try output_gpio.configureInterrupt(.both);
    output_gpio.setEventCallback(@ptrCast(&sink), EventSink.emit);

    var input = esp.embed.gpio.Pin.init(.{ .pin = input_pin });
    const input_gpio = input.handle();
    try input_gpio.setDirection(.input);

    var high = false;
    while (true) {
        high = !high;
        const target_level: embed.drivers.Gpio.Level = if (high) .high else .low;
        try output_gpio.write(target_level);
        const level = try output_gpio.read();
        log.info("output gpio{} target={s} level={s}; input gpio{} level={s}", .{
            output_pin,
            @tagName(target_level),
            @tagName(level),
            input_pin,
            @tagName(try input_gpio.read()),
        });
        grt.time.sleep(500 * grt.time.duration.MilliSecond);
    }
}
