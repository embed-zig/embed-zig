const glib = @import("glib");

const central_api = @import("../../Central.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return central_api.TestRunner(grt);
}
