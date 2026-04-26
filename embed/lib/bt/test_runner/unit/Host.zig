const glib = @import("glib");

const root_host = @import("../../Host.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return root_host.TestRunner(lib);
}
