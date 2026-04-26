const glib = @import("glib");

const client_mod = @import("../../../../host/gatt/client.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return client_mod.TestRunner(lib);
}
