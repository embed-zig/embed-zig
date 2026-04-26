const glib = @import("glib");

const server_mod = @import("../../../../host/gatt/server.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return server_mod.TestRunner(grt);
}
