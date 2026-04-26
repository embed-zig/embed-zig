const glib = @import("glib");

const hci_acl = @import("../../../../host/hci/acl.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return hci_acl.TestRunner(grt);
}
