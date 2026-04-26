const glib = @import("glib");

const att = @import("../../../host/att.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return att.TestRunner(lib);
}
