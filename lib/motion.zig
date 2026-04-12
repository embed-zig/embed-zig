//! motion — pure IMU and button gesture detection helpers.
//!
//! This module intentionally stays independent from `zux` and only operates on
//! normalized samples and derived actions.

pub const types = @import("motion/types.zig");
pub const GestureDetector = @import("motion/GestureDetector.zig");
pub const ClickDetector = @import("motion/ClickDetector.zig");
pub const Detector = GestureDetector;
pub const test_runner = struct {
    pub const unit = @import("motion/test_runner/unit.zig");
};

pub const AccelData = types.AccelData;
pub const GyroData = types.GyroData;
pub const Sample = types.Sample;
pub const GyroSample = types.GyroSample;
pub const Face = types.Face;
pub const ShakeData = types.ShakeData;
pub const TiltData = types.TiltData;
pub const FlipData = types.FlipData;
pub const FreeFallData = types.FreeFallData;
pub const Action = types.Action;
pub const Thresholds = types.Thresholds;
