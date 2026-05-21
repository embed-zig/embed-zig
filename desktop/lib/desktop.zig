const gstd = @import("gstd");

pub const App = @import("desktop/App.zig");
pub const device = @import("device.zig");
pub const http = @import("http.zig");
pub const log = @import("log.zig");
pub const runtime = gstd.runtime;
pub const PlatformCtx = struct {
    pub const AudioSystem = device.audio_system.AudioSystem;
};
pub const test_runner = struct {
    pub const unit = @import("desktop/test_runner/unit.zig");
};
