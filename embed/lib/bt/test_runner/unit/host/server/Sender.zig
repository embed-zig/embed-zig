const glib = @import("glib");

const sender_mod = @import("../../../../host/server/Sender.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return sender_mod.TestRunner(grt);
}
