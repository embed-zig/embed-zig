const glib = @import("glib");

const hci_root = @import("../../Hci.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return hci_root.TestRunner(lib);
}
