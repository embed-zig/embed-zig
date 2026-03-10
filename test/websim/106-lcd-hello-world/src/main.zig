const embed = @import("embed");
const firmware = @import("firmware_app");
const board = @import("board");

pub fn main() !void {
    try embed.websim.serve(board.hw, firmware.run, board.SessionSetup, .{});
}
