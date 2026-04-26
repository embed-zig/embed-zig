const glib = @import("glib");

const recv_mod = @import("../../../../host/xfer/recv.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return recv_mod.TestRunner(grt);
}
