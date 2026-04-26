const glib = @import("glib");

const gap_mod = @import("../../../host/Gap.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return gap_mod.TestRunner(grt);
}
