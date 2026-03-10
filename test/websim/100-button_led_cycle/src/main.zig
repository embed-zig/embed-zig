const std = @import("std");
const embed = @import("embed");
const firmware = @import("firmware_app");
const board = @import("board");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len >= 4 and std.mem.eql(u8, args[1], "test") and std.mem.eql(u8, args[2], "-d")) {
        const summary = try embed.websim.runTestDir(
            board.hw,
            firmware.run,
            board.SessionSetup,
            std.heap.page_allocator,
            args[3],
        );
        std.process.exit(if (summary.failed == 0) 0 else 1);
    }

    try embed.websim.serve(board.hw, firmware.run, board.SessionSetup, .{});
}
