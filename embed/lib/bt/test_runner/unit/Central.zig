const glib = @import("glib");

const central_api = @import("../../Central.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return central_api.TestRunner(lib);
}
