const bk = @import("../../bk.zig");
const embed = @import("embed_core");

const Display = @This();

pub const Config = struct {
    max_flush_rows: u16 = 480,
};

config: Config = .{},
display: ?embed.drivers.Display = null,

pub fn init(self: *Display) !void {
    if (self.display != null) return;

    earlyLog("[BK DISPLAY] init entered\r\n");

    var display = bk.embed.display.Rgb.display(.{
        .allocator = bk.heap.psram_allocator,
        .max_flush_rows = self.config.max_flush_rows,
    }) catch |err| {
        earlyLog("[BK DISPLAY] rgb create failed\r\n");
        return err;
    };
    errdefer display.deinit();
    earlyLog("[BK DISPLAY] rgb create ok\r\n");

    display.setEnabled(true) catch |err| {
        earlyLog("[BK DISPLAY] enable failed\r\n");
        return err;
    };
    earlyLog("[BK DISPLAY] enable ok\r\n");

    display.setBrightness(255) catch |err| {
        earlyLog("[BK DISPLAY] brightness failed\r\n");
        return err;
    };
    earlyLog("[BK DISPLAY] brightness ok\r\n");

    self.display = display;
}

pub fn deinit(self: *Display) void {
    if (self.display) |display| {
        display.deinit();
        self.display = null;
    }
}

pub fn handle(self: *Display) embed.drivers.Display {
    return self.display.?;
}

fn earlyLog(message: [:0]const u8) void {
    bk.armino.system.emergencyUartWriteString(0, message);
}
