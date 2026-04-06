//! motion — pure IMU motion detection helpers.
//!
//! This module intentionally stays independent from `zux` and only operates on
//! normalized samples and derived actions.

pub const types = @import("motion/types.zig");
pub const Detector = @import("motion/Detector.zig");
pub const test_runner = struct {
    pub const unit = @import("motion/test_runner/unit.zig");
};

pub const AccelData = types.AccelData;
pub const Sample = types.Sample;
pub const ShakeData = types.ShakeData;
pub const TiltData = types.TiltData;
pub const Action = types.Action;
pub const Thresholds = types.Thresholds;
