//! Time contract — platform-dependent timing.
//!
//! Impl must provide:
//!   fn milliTimestamp() i64

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () i64, &Impl.milliTimestamp);
    }

    return struct {
        pub fn milliTimestamp() i64 {
            return Impl.milliTimestamp();
        }
    };
}
