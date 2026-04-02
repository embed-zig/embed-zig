//! wifi — portable Wi-Fi abstractions and helpers.

pub const Ap = @import("wifi/Ap.zig");
pub const Sta = @import("wifi/Sta.zig");
pub const Wifi = @import("wifi/Wifi.zig");
pub const test_runner = struct {
    pub const sta = @import("wifi/test_runner/sta.zig");
    pub const ap = @import("wifi/test_runner/ap.zig");
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

test "wifi/unit_tests" {
    _ = @import("wifi/Ap.zig");
    _ = @import("wifi/Sta.zig");
    _ = @import("wifi/Wifi.zig");
    _ = @import("wifi/test_runner/sta.zig");
    _ = @import("wifi/test_runner/ap.zig");
}
