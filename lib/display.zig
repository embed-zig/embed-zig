//! display — portable display abstractions and helpers.

pub const Display = @import("display/Display.zig");
pub const rgb = Display.rgb;
pub const test_runner = struct {
    pub const unit = @import("display/test_runner/unit.zig");
};
