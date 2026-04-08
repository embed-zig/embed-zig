//! AT-style command/response helpers over byte streams (`lib/at`).

pub const Transport = @import("at/Transport.zig");
pub const LineReader = @import("at/LineReader.zig").LineReader;
pub const ReadLineError = @import("at/LineReader.zig").ReadLineError;
pub const Session = @import("at/Session.zig");
pub const Dte = @import("at/Dte.zig");
pub const Dce = @import("at/Dce.zig");
pub const test_runner = struct {
    pub const dte_loopback = @import("at/test_runner/dte_loopback.zig");
};

test "at/unit_tests/root_imports" {
    const std = @import("std");
    _ = Transport;
    _ = LineReader(64);
    const Lib = struct {
        pub const mem = @import("embed").mem;
        pub const testing = struct {
            pub const allocator = std.testing.allocator;
        };
        pub const time = struct {
            pub fn milliTimestamp() i64 {
                return 0;
            }
        };
    };
    _ = Session.make(Lib, 64);
    _ = Dte.make(Lib, 64);
    _ = Dce.handleLine;
    _ = test_runner.dte_loopback.make(Lib, 64);
}

test "integration_tests/at/dte_loopback" {
    const std = @import("std");
    const testing_mod = @import("testing");

    var t = testing_mod.T.new(std, .at_dte_loopback);
    defer t.deinit();

    t.run("at/dte_loopback", test_runner.dte_loopback.make(std, 256));
    if (!t.wait()) return error.TestFailed;
}

test "integration_tests/at/dte_serial_host" {
    const std = @import("std");
    const testing_mod = @import("testing");
    const dte_serial_host = @import("at/test_runner/dte_serial_host.zig");

    var t = testing_mod.T.new(std, .at_dte_serial_host);
    defer t.deinit();
    t.timeout(30 * std.time.ns_per_s);

    t.run("at/dte_serial_host", dte_serial_host.make(std, .{}));
    if (!t.wait()) return error.TestFailed;
}
