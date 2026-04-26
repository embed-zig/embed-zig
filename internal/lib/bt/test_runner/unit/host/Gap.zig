const glib = @import("glib");

const gap_mod = @import("../../../host/Gap.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return gap_mod.TestRunner(lib);
}
