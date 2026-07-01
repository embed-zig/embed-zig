const std = @import("std");
const embed = @import("embed");
const desktop_gpio = @import("desktop_gpio");

const log = std.log.scoped(.desktop_gpio_smoke);

const Sink = struct {
    calls: usize = 0,

    fn emit(ctx: *const anyopaque, event: embed.drivers.Gpio.Event) void {
        const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
        self.calls += 1;
        log.info("event edge={s} level={s} calls={}", .{
            @tagName(event.edge),
            @tagName(event.level),
            self.calls,
        });
    }
};

pub fn main() !void {
    var pin = desktop_gpio.Pin.init(.low);
    var sink = Sink{};
    const gpio = pin.handle();

    try gpio.setDirection(.output);
    try gpio.configureInterrupt(.both);
    gpio.setEventCallback(@ptrCast(&sink), Sink.emit);

    try gpio.write(.high);
    try gpio.write(.low);
    gpio.clearEventCallback();

    const level = try gpio.read();
    log.info("final level={s} callback_calls={}", .{ @tagName(level), sink.calls });
}
