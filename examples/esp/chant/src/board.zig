const embed = @import("embed");
const esp = @import("esp");
const binding = @import("szp_board");
const Display = @import("ui/Display.zig");
const player_ui = @import("ui/Ctrl.zig");

const Es7210 = embed.drivers.audio.Es7210;
const Es8311 = embed.drivers.audio.Es8311;
const log = esp.grt.std.log.scoped(.chant_board);

pub const audio_sample_rate = 16_000;
const es7210_address = @intFromEnum(Es7210.Address.ad1_ad0_01);
const es8311_address = @intFromEnum(Es8311.Address.ad0_low);
const ft5x06_address = 0x38;
const touch_width: u16 = 320;
const touch_height: u16 = 240;
const default_volume: u8 = 0xb0;
const es7210_ref_channel: u2 = 2;

var audio_adc: ?Es7210 = null;
var audio_codec: ?Es8311 = null;
var audio_ready = false;

pub const Track = player_ui.Track;
pub const Mode = player_ui.Mode;
pub const DisplayAction = player_ui.Action;

pub const TouchPoint = struct {
    x: u16,
    y: u16,
};

pub fn initNvs() !void {
    try check("szp_storage_init_nvs", binding.szp_storage_init_nvs());
}

pub fn mountStorage() !void {
    try check("szp_storage_mount", binding.szp_storage_mount());
}

pub fn unmountStorage() void {
    check("szp_storage_unmount", binding.szp_storage_unmount()) catch |err| {
        log.warn("storage unmount failed: {s}", .{@errorName(err)});
    };
}

pub fn storageInfo() !struct { total: usize, used: usize } {
    var total: usize = 0;
    var used: usize = 0;
    try check("szp_storage_info", binding.szp_storage_info(&total, &used));
    return .{ .total = total, .used = used };
}

pub fn initBoard() !void {
    try check("szp_board_init", binding.szp_board_init());
    try initDisplay();
    try initTouch();
}

pub fn initAudio() !void {
    if (audio_ready) return;

    try check("szp_audio_init", binding.szp_audio_init());

    const i2c = try binding.i2cDevice(es8311_address);
    var codec = Es8311.init(i2c, .{
        .address = es8311_address,
        .codec_mode = .dac_only,
    });

    try codec.open();
    const chip_id = try codec.readChipId();
    log.info("es8311 chip_id=0x{x}", .{chip_id});
    try codec.setSampleRate(audio_sample_rate);
    try codec.setBitsPerSample(.@"16bit");
    try codec.setFormat(.i2s);
    try codec.enable(true);
    try codec.setVolume(default_volume);
    try codec.setMute(false);

    const adc_i2c = try binding.i2cDevice(es7210_address);
    var adc = Es7210.init(adc_i2c, .{
        .address = es7210_address,
        .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true, .mic4 = true },
    });
    try adc.open();
    try adc.enable(true);
    try adc.setChannelGain(es7210_ref_channel, .@"0dB");

    audio_adc = adc;
    audio_codec = codec;
    try check("szp_audio_set_pa", binding.szp_audio_set_pa(true));
    audio_ready = true;
}

pub fn playTestTone(frequency_hz: u32, duration_ms: u32) !void {
    try initAudio();
    try check("szp_audio_play_test_tone", binding.szp_audio_play_test_tone(frequency_hz, duration_ms));
}

pub fn writePcm(samples: []const i16) !void {
    if (samples.len == 0) return;
    try check("szp_audio_write_i16", binding.szp_audio_write_i16(samples.ptr, samples.len));
}

pub fn startMicrophoneStream() !void {
    try initAudio();
    try check("szp_audio_mic_start", binding.szp_audio_mic_start());
}

pub fn processMicrophoneFrame() !void {
    try check("szp_audio_mic_process_frame", binding.szp_audio_mic_process_frame());
}

pub fn stopMicrophoneStream() void {
    check("szp_audio_mic_stop", binding.szp_audio_mic_stop()) catch |err| {
        log.warn("mic stream stop failed: {s}", .{@errorName(err)});
    };
}

pub fn startMicrophoneCapture() !void {
    try initAudio();
    try check("szp_audio_mic_capture_start", binding.szp_audio_mic_capture_start());
}

pub fn readMicrophoneFrame(mic0: []i16, mic1: []i16, ref: []i16) !usize {
    if (mic0.len == 0) return 0;
    if (mic1.len < mic0.len or ref.len < mic0.len) return error.BoardCallFailed;
    var sample_count: usize = 0;
    try check("szp_audio_mic_read_i16", binding.szp_audio_mic_read_i16(mic0.ptr, mic1.ptr, ref.ptr, mic0.len, &sample_count));
    return sample_count;
}

pub fn stopMicrophoneCapture() void {
    check("szp_audio_mic_capture_stop", binding.szp_audio_mic_capture_stop()) catch |err| {
        log.warn("mic capture stop failed: {s}", .{@errorName(err)});
    };
}

pub fn processAfeFrame(mic0: []const i16, mic1: []const i16, ref: []const i16, out: []i16) !usize {
    if (mic0.len == 0) return 0;
    if (mic1.len < mic0.len or ref.len < mic0.len) return error.BoardCallFailed;
    var out_count: usize = 0;
    try check(
        "szp_audio_afe_process_i16",
        binding.szp_audio_afe_process_i16(mic0.ptr, mic1.ptr, ref.ptr, mic0.len, out.ptr, out.len, &out_count),
    );
    return out_count;
}

pub fn setVolume(volume: u8) !void {
    if (audio_codec == null) try initAudio();
    if (audio_codec) |*codec| {
        try codec.setVolume(volume);
        return;
    }
    return error.BoardCallFailed;
}

pub fn setSpeakerEnabled(enabled: bool) !void {
    if (enabled) try initAudio();
    if (!audio_ready and !enabled) return;
    try check("szp_audio_set_pa", binding.szp_audio_set_pa(enabled));
}

pub fn setMicrophoneGain(gain_db: i8) !void {
    if (audio_adc == null) try initAudio();
    if (audio_adc) |*adc| {
        try adc.setGainAll(microphoneGainFromDb(gain_db));
        try adc.setChannelGain(es7210_ref_channel, .@"0dB");
        return;
    }
    return error.BoardCallFailed;
}

pub fn initButton() !void {
    try check("szp_button_init", binding.szp_button_init());
}

pub fn buttonPressedRaw() bool {
    return binding.szp_button_read_raw();
}

pub fn pollTouch() !?TouchPoint {
    var points: [1]u8 = .{0};
    try touchRead(0x02, &points);
    const point_count = points[0] & 0x0f;
    if (point_count == 0 or point_count > 5) return null;

    var data: [4]u8 = undefined;
    try touchRead(0x03, &data);

    const raw_x = (@as(u16, data[0] & 0x0f) << 8) | data[1];
    const raw_y = (@as(u16, data[2] & 0x0f) << 8) | data[3];

    // Match the LCD rotation used by the reference board example:
    // swap XY, then mirror X before the swap.
    const x = if (raw_y >= touch_width) touch_width - 1 else raw_y;
    const y = if (raw_x >= touch_height) 0 else touch_height - 1 - raw_x;
    return .{ .x = x, .y = y };
}

pub fn initDisplay() !void {
    try Display.init();
    player_ui.setTouchReader(readTouchForUi);
}

pub fn showTrack(track: Track) !void {
    try showPlayer(track, .music, true, default_volume);
}

pub fn showPlayer(track: Track, mode: Mode, playing: bool, volume: u8) !void {
    try Display.init();
    try player_ui.show(Display.driver(), track, mode, playing, volume);
}

pub fn tickDisplay(elapsed_ms: u32) void {
    player_ui.tick(elapsed_ms);
}

pub fn takeDisplayAction() DisplayAction {
    return player_ui.takeAction();
}

fn check(name: []const u8, rc: c_int) !void {
    if (rc == binding.esp_ok) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    return error.BoardCallFailed;
}

fn microphoneGainFromDb(gain_db: i8) Es7210.Gain {
    if (gain_db < 3) return .@"0dB";
    if (gain_db < 6) return .@"3dB";
    if (gain_db < 9) return .@"6dB";
    if (gain_db < 12) return .@"9dB";
    if (gain_db < 15) return .@"12dB";
    if (gain_db < 18) return .@"15dB";
    if (gain_db < 21) return .@"18dB";
    if (gain_db < 24) return .@"21dB";
    if (gain_db < 27) return .@"24dB";
    if (gain_db < 30) return .@"27dB";
    if (gain_db < 33) return .@"30dB";
    if (gain_db < 34) return .@"33dB";
    if (gain_db < 36) return .@"34.5dB";
    if (gain_db < 37) return .@"36dB";
    return .@"37.5dB";
}

fn initTouch() !void {
    try touchWrite(0x80, 70);
    try touchWrite(0x81, 60);
    try touchWrite(0x82, 16);
    try touchWrite(0x83, 60);
    try touchWrite(0x84, 10);
    try touchWrite(0x85, 20);
    try touchWrite(0x87, 2);
    try touchWrite(0x88, 12);
    try touchWrite(0x89, 40);
    log.info("ft5x06 touch initialized", .{});
}

fn touchWrite(reg: u8, value: u8) !void {
    const i2c = try binding.i2cDevice(ft5x06_address);
    try i2c.write(ft5x06_address, &.{ reg, value });
}

fn touchRead(reg: u8, data: []u8) !void {
    const i2c = try binding.i2cDevice(ft5x06_address);
    try i2c.writeRead(ft5x06_address, &.{reg}, data);
}

fn readTouchForUi() ?player_ui.TouchPoint {
    const point = pollTouch() catch return null;
    const touch = point orelse return null;
    return .{ .x = touch.x, .y = touch.y };
}
