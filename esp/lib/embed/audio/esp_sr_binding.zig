pub const esp_ok: c_int = 0;

pub const Config = extern struct {
    sample_rate_hz: u32,
    audio_frame_samples: usize,
    mic_count: usize,
    ref_count: usize,
    enable_aec: c_int,
    aec_mode: i32,
    aec_filter_length: i32,
    aec_nlp_level: i32,
    aec_linear_only: c_int,
};

pub extern fn espz_esp_sr_afe_configure(config: *const Config) c_int;
pub extern fn espz_esp_sr_afe_init() c_int;
pub extern fn espz_esp_sr_afe_deinit() void;
pub extern fn espz_esp_sr_afe_reset() c_int;
pub extern fn espz_esp_sr_afe_process_i16(
    mic: [*]const i16,
    ref: [*]const i16,
    sample_count: usize,
    out: [*]i16,
    out_capacity: usize,
    out_count: *usize,
) c_int;
