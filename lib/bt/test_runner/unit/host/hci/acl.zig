const hci_acl = @import("../../../../host/hci/acl.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return hci_acl.TestRunner(lib);
}
