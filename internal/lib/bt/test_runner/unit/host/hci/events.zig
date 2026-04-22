const hci_events = @import("../../../../host/hci/events.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return hci_events.TestRunner(lib);
}
