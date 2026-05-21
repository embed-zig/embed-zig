const State = @import("State.zig");

pub const Start = struct {
    pub const kind = .audio_system_start;

    source_id: u32,
};

pub const Stop = struct {
    pub const kind = .audio_system_stop;

    source_id: u32,
};

pub const SetGain = struct {
    pub const kind = .audio_system_set_gain;

    source_id: u32,
    gain_db: i8,
};

pub const IncGain = struct {
    pub const kind = .audio_system_inc_gain;

    source_id: u32,
};

pub const DecGain = struct {
    pub const kind = .audio_system_dec_gain;

    source_id: u32,
};

pub const SetMicGains = struct {
    pub const kind = .audio_system_set_mic_gains;

    source_id: u32,
    mic_gain_count: u8 = 0,
    mic_gains: [State.max_mic_gains]?i8 = [_]?i8{null} ** State.max_mic_gains,
};
