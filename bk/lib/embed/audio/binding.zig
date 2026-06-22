pub const ok: c_int = 0;

pub extern fn bk_embed_audio_onboard_speaker_init(
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    volume: c_int,
    frame_size: u32,
    pool_size: u32,
) c_int;
pub extern fn bk_embed_audio_onboard_speaker_deinit() void;
pub extern fn bk_embed_audio_onboard_speaker_enable() c_int;
pub extern fn bk_embed_audio_onboard_speaker_disable() c_int;
pub extern fn bk_embed_audio_onboard_speaker_write(data: [*]const u8, len: usize) c_int;
pub extern fn bk_embed_audio_onboard_speaker_set_volume(volume: c_int) c_int;

pub extern fn bk_embed_audio_onboard_mic_init(
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    adc_gain: c_int,
    frame_size: u32,
    pool_size: u32,
) c_int;
pub extern fn bk_embed_audio_onboard_mic_deinit() void;
pub extern fn bk_embed_audio_onboard_mic_enable() c_int;
pub extern fn bk_embed_audio_onboard_mic_disable() c_int;
pub extern fn bk_embed_audio_onboard_mic_read(data: [*]u8, len: usize) c_int;
pub extern fn bk_embed_audio_onboard_mic_set_gain(adc_gain: c_int) c_int;

pub extern fn bk_embed_audio_aec_init(
    sample_rate: u32,
    frame_samples: u32,
    delay_samples: u32,
    ec_depth: u32,
    tx_rx_thr: u32,
    tx_rx_flr: u32,
    ref_scale: u8,
    ns_level: u8,
    ns_para: u8,
    voice_volume: u32,
    drc: u32,
) c_int;
pub extern fn bk_embed_audio_aec_deinit() void;
pub extern fn bk_embed_audio_aec_process(
    ref_data: [*]const i16,
    mic_data: [*]const i16,
    out_data: [*]i16,
    samples: usize,
) c_int;
