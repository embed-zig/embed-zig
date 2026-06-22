const glib = @import("glib");

pub const audio = struct {
    pub const default_gain_db: i8 = 0;
    pub const maximum_gain_db: i8 = 6;
    pub const minimum_gain_db: i8 = -60;
    pub const gain_step_db: i8 = 1;
};

pub const player = struct {
    pub const default_sample_rate_hz: u32 = 16_000;
    pub const frame_sample_count: usize = 320;
    pub const track_buffer_capacity: usize = frame_sample_count * 16;
};

pub const recorder = struct {
    pub const retry_interval = 2 * glib.time.duration.MilliSecond;
    pub const slow_io_threshold = 20 * glib.time.duration.MilliSecond;
    pub const loopback_gain: f32 = 1.0;
    pub const report_stride: usize = 500;
    pub const frame_sample_count: usize = 320;
    pub const track_buffer_capacity: usize = frame_sample_count * 64;
};

pub const ui = struct {
    pub const poll_interval = 10 * glib.time.duration.MilliSecond;
};

pub const notify_timeout = 1 * glib.time.duration.MilliSecond;
