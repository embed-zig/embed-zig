const glib = @import("glib");

pub const Command = @import("cmd/Command.zig");
pub const Executor = @import("cmd/Executor.zig");
pub const Output = @import("cmd/Output.zig");
pub const Parser = @import("cmd/Parser.zig");
pub const bt_kcp = @import("cmd/bt_kcp.zig");
pub const common = @import("cmd/common.zig");
pub const desktop_tcp = @import("cmd/desktop_tcp.zig");
pub const uart = @import("cmd/uart.zig");

pub const test_runner = struct {
    pub const unit = struct {
        pub fn make(comptime grt: type) glib.testing.TestRunner {
            return TestRunner(grt);
        }
    };
};

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return @import("cmd/test_runner/unit.zig").make(grt);
}
