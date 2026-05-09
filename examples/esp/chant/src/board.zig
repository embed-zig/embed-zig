const embed = @import("embed");
const esp = @import("esp");
const binding = @import("szp_board");
const Display = @import("ui/Display.zig");
const Touch = @import("ui/Touch.zig");
const player_ui = @import("ui/Ctrl.zig");

const Es7210 = embed.drivers.audio.Es7210;
const Es8311 = embed.drivers.audio.Es8311;
const log = esp.grt.std.log.scoped(.chant_board);

pub const audio_sample_rate = 16_000;
const es7210_address = @intFromEnum(Es7210.Address.ad1_ad0_01);
const es8311_address = @intFromEnum(Es8311.Address.ad0_low);
const default_volume: u8 = 0xb0;
const es7210_ref_channel: u2 = 2;

var audio_adc: ?Es7210 = null;
var audio_codec: ?Es8311 = null;
var audio_ready = false;

pub const Track = player_ui.Track;
pub const Mode = player_ui.Mode;
pub const DisplayAction = player_ui.Action;

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

pub fn initDisplay() !void {
    try Display.init();
    try Touch.init();
    player_ui.setTouch(Touch.driver());
}

pub fn showTrack(track: Track) !void {
    try showPlayer(track, .music, true, default_volume);
}

pub fn showPlayer(track: Track, mode: Mode, playing: bool, volume: u8) !void {
    try Display.init();
    try Touch.init();
    try player_ui.show(Display.driver(), Touch.driver(), track, mode, playing, volume);
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
