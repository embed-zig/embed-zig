//! wifi — portable Wi-Fi abstractions and helpers.

pub const Ap = @import("wifi/Ap.zig");
pub const Sta = @import("wifi/Sta.zig");
pub const Wifi = @import("wifi/Wifi.zig");
pub const test_runner = struct {
    pub const unit = @import("wifi/test_runner/unit.zig");
    pub const integration = @import("wifi/test_runner/integration.zig");
};

const root = @This();

pub fn make(comptime lib: type) type {
    return struct {
        pub const Ap = root.Ap;
        pub const Sta = root.Sta;
        pub fn makeWifi(comptime Impl: type) type {
            return root.Wifi.make(lib, Impl);
        }
    };
}
