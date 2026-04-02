//! ledstrip — portable LED strip abstractions and animation helpers.

pub const Color = @import("ledstrip/Color.zig");
pub const Frame = @import("ledstrip/Frame.zig");
pub const Transition = @import("ledstrip/Transition.zig");
pub const Animator = @import("ledstrip/Animator.zig");
pub const LedStrip = @import("ledstrip/LedStrip.zig");
pub const test_runner = struct {
    pub const animator = @import("ledstrip/test_runner/animator.zig");
};
pub const make = LedStrip.make;

test "ledstrip/unit_tests" {
    _ = @import("ledstrip/Color.zig");
    _ = @import("ledstrip/Frame.zig");
    _ = @import("ledstrip/Transition.zig");
    _ = @import("ledstrip/Animator.zig");
    _ = @import("ledstrip/LedStrip.zig");
    _ = @import("ledstrip/test_runner/animator.zig");
}

test "ledstrip/integration_tests" {
    _ = @import("integration/ledstrip_animator.zig");
}
