const glib = @import("glib");

const l2cap = @import("../../../host/l2cap.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return l2cap.TestRunner(grt);
}
