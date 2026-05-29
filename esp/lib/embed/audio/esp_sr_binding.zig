pub const esp_ok: c_int = 0;

pub const Config = extern struct {
    sample_rate_hz: u32,
    mic_count: usize,
    ref_count: usize,
    afe_task_priority: i32,
    speech_enhancement: c_int,
    voice_communication_agc: c_int,
    voice_communication_agc_gain: i32,
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
