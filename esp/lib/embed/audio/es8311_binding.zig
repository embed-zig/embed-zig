pub const esp_ok: c_int = 0;

pub const Config = extern struct {
    i2s_port: i32,
    sample_rate_hz: u32,
    mclk_gpio: i32,
    bclk_gpio: i32,
    ws_gpio: i32,
    dout_gpio: i32,
    din_gpio: i32,
    mono_chunk_samples: usize,
    rx_channel_count: usize,
    mic_lane: i32,
    ref_lane: i32,
};

pub extern fn espz_es8311_audio_configure(config: *const Config) c_int;
pub extern fn espz_es8311_audio_init() c_int;
pub extern fn espz_es8311_audio_deinit() void;
pub extern fn espz_es8311_audio_write_raw(data: [*]const u8, byte_count: usize, bytes_written: *usize) c_int;
pub extern fn espz_es8311_audio_read_raw(data: [*]u8, byte_capacity: usize, bytes_read: *usize) c_int;
pub extern fn espz_es8311_audio_mic_capture_start() c_int;
pub extern fn espz_es8311_audio_mic_capture_stop() c_int;
