const host_hci = @import("../../../host/Hci.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return host_hci.TestRunner(lib);
}
