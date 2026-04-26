const glib = @import("glib");

const host_central = @import("../../../host/Central.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return host_central.TestRunner(grt);
}
