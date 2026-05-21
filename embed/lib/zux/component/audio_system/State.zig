pub const max_mic_gains: usize = 8;

started: bool = false,
gain_db: i8 = 0,
min_gain_db: i8 = -60,
max_gain_db: i8 = 6,
gain_step_db: i8 = 1,
mic_gain_count: u8 = 0,
mic_gains: [max_mic_gains]?i8 = [_]?i8{null} ** max_mic_gains,
