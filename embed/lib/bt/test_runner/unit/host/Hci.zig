const glib = @import("glib");

const host_hci = @import("../../../host/Hci.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return host_hci.TestRunner(lib);
}
