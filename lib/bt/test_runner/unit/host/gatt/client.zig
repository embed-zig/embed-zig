const client_mod = @import("../../../../host/gatt/client.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return client_mod.TestRunner(lib);
}
