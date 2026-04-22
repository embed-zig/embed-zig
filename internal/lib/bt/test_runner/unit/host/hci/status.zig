const hci_status = @import("../../../../host/hci/status.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return hci_status.TestRunner(lib);
}
