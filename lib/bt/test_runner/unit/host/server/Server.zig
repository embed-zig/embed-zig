const server_mod = @import("../../../../host/Server.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return server_mod.TestRunner(lib);
}
