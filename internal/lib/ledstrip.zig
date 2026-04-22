//! ledstrip — portable LED strip abstractions and animation helpers.

pub const Color = @import("ledstrip/Color.zig");
pub const Frame = @import("ledstrip/Frame.zig");
pub const Transition = @import("ledstrip/Transition.zig");
pub const Animator = @import("ledstrip/Animator.zig");
pub const LedStrip = @import("ledstrip/LedStrip.zig");
pub const test_runner = struct {
    pub const unit = @import("ledstrip/test_runner/unit.zig");
    pub const animator = @import("ledstrip/test_runner/animator.zig");
};
pub const make = LedStrip.make;
