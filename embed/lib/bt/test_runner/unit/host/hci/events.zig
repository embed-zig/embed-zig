const glib = @import("glib");

const hci_events = @import("../../../../host/hci/events.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return hci_events.TestRunner(grt);
}
