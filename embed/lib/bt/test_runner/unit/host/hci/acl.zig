const glib = @import("glib");

const hci_acl = @import("../../../../host/hci/acl.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return hci_acl.TestRunner(lib);
}
