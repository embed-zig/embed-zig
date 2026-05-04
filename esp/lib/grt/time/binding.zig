pub const time_t = i64;

pub const timespec = extern struct {
    tv_sec: time_t,
    tv_nsec: c_long,
};

pub extern fn espz_grt_time_uptime_us() i64;
pub extern fn espz_newlib_clock_gettime_monotonic(ts: *timespec) c_int;
pub extern fn espz_newlib_clock_gettime_realtime(ts: *timespec) c_int;
