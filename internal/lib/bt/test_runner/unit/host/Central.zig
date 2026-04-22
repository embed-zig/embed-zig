const host_central = @import("../../../host/Central.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return host_central.TestRunner(lib);
}
