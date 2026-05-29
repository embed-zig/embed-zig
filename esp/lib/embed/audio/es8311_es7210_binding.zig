pub const esp_ok: c_int = 0;

pub const Config = extern struct {
    i2s_port: i32,
    sample_rate_hz: u32,
    mclk_gpio: i32,
    bclk_gpio: i32,
    ws_gpio: i32,
    dout_gpio: i32,
    din_gpio: i32,
    i2s_data_bit_width: i32,
    i2s_slot_mode: i32,
    mono_chunk_samples: usize,
    rx_channel_count: usize,
    mic_count: usize,
    mic0_lane: i32,
    mic1_lane: i32,
    /// Hardware reference lane, or -1 when the board has no ADC reference lane.
    ref_lane: i32,
};

pub extern fn espz_es8311_es7210_audio_configure(config: *const Config) c_int;
pub extern fn espz_es8311_es7210_audio_init() c_int;
pub extern fn espz_es8311_es7210_audio_deinit() void;
pub extern fn espz_es8311_es7210_audio_write_raw(data: [*]const u8, byte_count: usize, bytes_written: *usize) c_int;
pub extern fn espz_es8311_es7210_audio_read_raw(data: [*]u8, byte_capacity: usize, bytes_read: *usize) c_int;
pub extern fn espz_es8311_es7210_audio_write_i16(pcm: [*]const i16, sample_count: usize) c_int;
pub extern fn espz_es8311_es7210_audio_mic_capture_start() c_int;
pub extern fn espz_es8311_es7210_audio_mic_capture_stop() c_int;
pub extern fn espz_es8311_es7210_audio_mic_read_i16(
    mic0: [*]i16,
    mic1: ?[*]i16,
    ref: [*]i16,
    sample_capacity: usize,
    sample_count: *usize,
) c_int;
