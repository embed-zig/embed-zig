const embed = @import("embed");
const esp = @import("esp");
const selected_board = @import("selected_board");

const grt = esp.grt;
const Board = selected_board.Board;

const log = grt.std.log.scoped(.blink);

const blink_interval: u64 = @intCast(500 * grt.time.duration.MilliSecond);

pub export fn zig_esp_main() void {
    run() catch |err| {
        log.err("blink failed: {s}", .{@errorName(err)});
        @panic("blink failed");
    };
}

fn run() !void {
    var board_impl = try Board.init(.{});
    defer board_impl.deinit();

    try board_impl.powerOn();
    try board_impl.start();

    const board = board_impl.asBoard();
    const strip = try board.ledStrip("strip");

    var led_on = false;
    while (true) {
        if (led_on) {
            strip.setPixel(0, embed.ledstrip.Color.rgb(16, 16, 16));
        } else {
            strip.clear();
        }
        strip.refresh();

        log.info("blink state={s} board={s}", .{ if (led_on) "on" else "off", boardName() });
        led_on = !led_on;
        grt.std.Thread.sleep(blink_interval);
    }
}

fn boardName() []const u8 {
    if (@hasDecl(Board, "metadata")) {
        return Board.metadata.name;
    }
    return "unknown";
}
