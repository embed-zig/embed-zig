const std = @import("std");
const esp = @import("esp");
const selected_app = @import("selected_app");
const selected_board = @import("selected_board");

const sleep_interval: u64 = @intCast(1 * esp.grt.time.duration.Second);

const PlatformCtx = struct {};

const ZuxAppType = selected_app.make(PlatformCtx, esp.grt);
const App = esp.Launcher.make(ZuxAppType, selected_board.Board);

var app_heap: [128 * 1024]u8 align(16) = undefined;

pub export fn zig_esp_main() void {
    run() catch @panic("esp launcher failed");
}

fn run() !void {
    var app_heap_allocator = std.heap.FixedBufferAllocator.init(&app_heap);
    var launcher = try App.init(app_heap_allocator.allocator(), .{
        .pipeline_spawn_config = .{
            .stack_size = 24 * 1024,
        },
        .poller_spawn_config = .{
            .stack_size = 16 * 1024,
        },
    });
    defer launcher.deinit();

    try launcher.start();
    defer launcher.stop() catch {};

    while (true) {
        esp.grt.std.Thread.sleep(sleep_interval);
    }
}
