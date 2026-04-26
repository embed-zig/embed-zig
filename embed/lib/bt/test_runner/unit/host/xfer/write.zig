const glib = @import("glib");

const write_mod = @import("../../../../host/xfer/write.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return write_mod.TestRunner(grt);
}
