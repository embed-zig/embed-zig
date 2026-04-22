const root_host = @import("../../Host.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return root_host.TestRunner(lib);
}
