const log = @import("esp").grt.std.log.scoped(.opus_player_board);

pub const Track = enum(c_int) {
    twinkle = 0,
    happy_birthday = 1,
    doll_bear = 2,
};

extern fn szp_board_init() c_int;
extern fn szp_storage_init_nvs() c_int;
extern fn szp_storage_mount() c_int;
extern fn szp_storage_info(total: *usize, used: *usize) c_int;
extern fn szp_storage_unmount() c_int;
extern fn szp_audio_init() c_int;
extern fn szp_audio_write_i16(pcm: [*]const i16, sample_count: usize) c_int;
extern fn szp_audio_play_test_tone(frequency_hz: u32, duration_ms: u32) c_int;
extern fn szp_button_init() c_int;
extern fn szp_button_read_raw() bool;
extern fn szp_display_init() c_int;
extern fn szp_display_show_track(track: Track) c_int;

pub fn initNvs() !void {
    try check("szp_storage_init_nvs", szp_storage_init_nvs());
}

pub fn mountStorage() !void {
    try check("szp_storage_mount", szp_storage_mount());
}

pub fn unmountStorage() void {
    check("szp_storage_unmount", szp_storage_unmount()) catch |err| {
        log.warn("storage unmount failed: {s}", .{@errorName(err)});
    };
}

pub fn storageInfo() !struct { total: usize, used: usize } {
    var total: usize = 0;
    var used: usize = 0;
    try check("szp_storage_info", szp_storage_info(&total, &used));
    return .{ .total = total, .used = used };
}

pub fn initBoard() !void {
    try check("szp_board_init", szp_board_init());
}

pub fn initAudio() !void {
    try check("szp_audio_init", szp_audio_init());
}

pub fn playTestTone(frequency_hz: u32, duration_ms: u32) !void {
    try check("szp_audio_play_test_tone", szp_audio_play_test_tone(frequency_hz, duration_ms));
}

pub fn writePcm(samples: []const i16) !void {
    if (samples.len == 0) return;
    try check("szp_audio_write_i16", szp_audio_write_i16(samples.ptr, samples.len));
}

pub fn initButton() !void {
    try check("szp_button_init", szp_button_init());
}

pub fn buttonPressedRaw() bool {
    return szp_button_read_raw();
}

pub fn initDisplay() !void {
    try check("szp_display_init", szp_display_init());
}

pub fn showTrack(track: Track) !void {
    try check("szp_display_show_track", szp_display_show_track(track));
}

fn check(name: []const u8, rc: c_int) !void {
    if (rc == 0) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    return error.BoardCallFailed;
}
