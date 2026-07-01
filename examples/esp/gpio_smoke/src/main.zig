const embed = @import("embed");
const esp = @import("esp");

const grt = esp.grt;
const log = grt.std.log.scoped(.gpio_smoke);

const output_pin: c_int = 2;
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
    const output_gpio = output.handle();
    try output_gpio.setDirection(.output);

    var input = esp.embed.gpio.Pin.init(.{ .pin = input_pin });
    var sink = EventSink{};
    const input_gpio = input.handle();
    try input_gpio.setDirection(.input);
    try input_gpio.configureInterrupt(.both);
    input_gpio.setEventCallback(@ptrCast(&sink), EventSink.emit);

    var high = false;
    while (true) {
        high = !high;
        try output_gpio.write(if (high) .high else .low);
        const level = try output_gpio.read();
        log.info("output gpio{} level={s}; input gpio{} level={s}", .{
            output_pin,
            @tagName(level),
            input_pin,
            @tagName(try input_gpio.read()),
        });
        grt.time.sleep(500 * grt.time.duration.MilliSecond);
    }
}
