const glib = @import("glib");

const send_mod = @import("../../../../host/xfer/send.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return send_mod.TestRunner(lib);
}
