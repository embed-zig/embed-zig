const glib = @import("glib");

const read_mod = @import("../../../../host/xfer/read.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return read_mod.TestRunner(grt);
}
