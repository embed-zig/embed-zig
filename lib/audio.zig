//! audio — portable audio abstractions and helpers.

pub const AudioSystem = @import("audio/AudioSystem.zig");
pub const Mixer = @import("audio/Mixer.zig");
pub const Mic = @import("audio/Mic.zig");
pub const Speaker = @import("audio/Speaker.zig");
pub const test_runner = struct {
    pub const mixer = @import("audio/test_runner/mixer.zig");
};

test "audio/unit_tests" {}
