const glib = @import("glib");

const receiver_mod = @import("../../../../host/server/Receiver.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return receiver_mod.TestRunner(lib);
}
