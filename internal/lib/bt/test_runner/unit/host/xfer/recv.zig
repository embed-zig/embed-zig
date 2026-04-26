const glib = @import("glib");

const recv_mod = @import("../../../../host/xfer/recv.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return recv_mod.TestRunner(lib);
}
