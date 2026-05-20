const embed = @import("embed");
const esp = @import("esp");
const player_ui = @import("ui/Ctrl.zig");

const Board = embed.boards.szp.Board;
const audio_allocator = esp.heap.Allocator(.{ .caps = .spiram_8bit, .alignment = .align_u32 });
const thread_allocator = esp.heap.Allocator(.{ .caps = .internal_8bit, .alignment = .align_u32 });
const audio_read_thread_stack_size = 16 * 1024;
const audio_write_thread_stack_size = 8 * 1024;

var native_board: ?Board = null;

pub const audio_sample_rate = Board.audio_sample_rate;
pub const AudioSystem = Board.AudioSystem;
pub const Track = player_ui.Track;
pub const Mode = player_ui.Mode;
pub const DisplayAction = player_ui.Action;

pub fn initNvs() !void {
    const board = try ensureBoard();
    try board.initNvs();
}

pub fn mountStorage() !void {
    const board = try ensureBoard();
    try board.mountStorage();
}

pub fn unmountStorage() void {
    if (native_board) |*board| {
        board.unmountStorage();
    }
}

pub fn storageInfo() !Board.StorageInfo {
    const board = try ensureBoard();
    return board.storageInfo();
}

pub fn initBoard() !void {
    const board = try ensureBoard();
    try board.powerOn();
    try board.start();
    try initDisplay();
}

pub fn audioSystem() !*AudioSystem {
    const board = try ensureStartedBoard();
    return board.audioSystem("audio");
}

pub fn initButton() !void {
    const board = try ensureStartedBoard();
    _ = try board.singleButton("button");
}

pub fn buttonPressedRaw() bool {
    const board = ensureStartedBoard() catch return false;
    const button = board.singleButton("button") catch return false;
    return button.isPressed() catch false;
}

pub fn initDisplay() !void {
    const board = try ensureStartedBoard();
    try board.initDisplay();
    player_ui.setTouch(try board.touch("touch"));
}

pub fn showTrack(track: Track) !void {
    try showPlayer(track, .music, true, 0xb0);
}

pub fn showPlayer(track: Track, mode: Mode, playing: bool, volume: u8) !void {
    const board = try ensureStartedBoard();
    try board.initDisplay();
    try player_ui.show(try board.display("display"), try board.touch("touch"), track, mode, playing, volume);
}

pub fn tickDisplay(elapsed_ms: u32) void {
    player_ui.tick(elapsed_ms);
}

pub fn takeDisplayAction() DisplayAction {
    return player_ui.takeAction();
}

fn ensureBoard() !*Board {
    if (native_board == null) {
        native_board = try Board.init(.{
            .audio_allocator = audio_allocator,
            .audio_system_config = .{
                .read_thread = .{
                    .stack_size = audio_read_thread_stack_size,
                    .name = "audio_read",
                    .allocator = thread_allocator,
                    .core_id = 0,
                },
                .write_thread = .{
                    .stack_size = audio_write_thread_stack_size,
                    .name = "audio_write",
                    .allocator = thread_allocator,
                    .core_id = 1,
                },
            },
        });
    }
    return &(native_board orelse unreachable);
}

fn ensureStartedBoard() !*Board {
    const board = try ensureBoard();
    switch (board.state()) {
        .powered_on, .started => {},
        else => {
            try board.powerOn();
            try board.start();
        },
    }
    return board;
}
