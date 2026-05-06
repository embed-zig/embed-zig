const esp = @import("esp");
const opus_osal = @import("opus_osal");
const assets = @import("assets.zig");
const board = @import("board.zig");
const player = @import("player.zig");

const log = esp.grt.std.log.scoped(.opus_player_main);
const opus_exports = opus_osal.make(esp.grt, esp.heap.Allocator(.{
    .caps = .internal_8bit,
    .alignment = .align_u32,
}));

comptime {
    _ = opus_exports.opus_alloc_scratch;
}

pub export fn zig_esp_main() void {
    board.initNvs() catch |err| fail("nvs", err);
    board.mountStorage() catch |err| fail("spiffs mount", err);
    defer board.unmountStorage();

    const info = board.storageInfo() catch |err| fail("spiffs info", err);
    log.info("spiffs total={d} used={d}", .{ info.total, info.used });

    board.initBoard() catch |err| fail("board init", err);
    log.info("board initialized; tracks={d}", .{assets.tracks.len});

    player.run();
}

fn fail(name: []const u8, err: anyerror) noreturn {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    @panic("opus_player init failed");
}
