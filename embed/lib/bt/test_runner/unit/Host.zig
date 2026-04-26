const glib = @import("glib");

const root_host = @import("../../Host.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return root_host.TestRunner(grt);
}
