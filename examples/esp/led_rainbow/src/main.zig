const embed = @import("embed");
const esp = @import("esp");

const grt = esp.grt;
const Board = embed.boards.devkit.Board;

const log = grt.std.log.scoped(.led_rainbow);

const frame_interval: u64 = @intCast(20 * grt.time.duration.MilliSecond);

pub export fn zig_esp_main() void {
    run() catch |err| {
        log.err("led_rainbow failed: {s}", .{@errorName(err)});
        @panic("led_rainbow failed");
    };
}

fn run() !void {
    var board_impl = try Board.init(.{});
    defer board_impl.deinit();

    try board_impl.powerOn();
    try board_impl.start();

    const board = board_impl.asBoard();
    const strip = try board.ledStrip("strip");

    log.info("starting rainbow animation on {s}", .{boardName()});

    var hue: u16 = 0;
    while (true) {
        strip.setPixel(0, wheel(hue));
        strip.refresh();
        hue +%= 4;
        if (hue >= 1536) hue -= 1536;
        grt.std.Thread.sleep(frame_interval);
    }
}

fn wheel(pos: u16) embed.ledstrip.Color {
    const segment: u16 = pos / 256;
    const x: u8 = @intCast(pos % 256);
    return switch (segment) {
        0 => embed.ledstrip.Color.rgb(255, x, 0),
        1 => embed.ledstrip.Color.rgb(255 - x, 255, 0),
        2 => embed.ledstrip.Color.rgb(0, 255, x),
        3 => embed.ledstrip.Color.rgb(0, 255 - x, 255),
        4 => embed.ledstrip.Color.rgb(x, 0, 255),
        else => embed.ledstrip.Color.rgb(255, 0, 255 - x),
    };
}

fn boardName() []const u8 {
    if (@hasDecl(Board, "metadata")) {
        return Board.metadata.name;
    }
    return "unknown";
}
