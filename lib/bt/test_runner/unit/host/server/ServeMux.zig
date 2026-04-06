const serve_mux_mod = @import("../../../../host/server/ServeMux.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return serve_mux_mod.TestRunner(lib);
}
