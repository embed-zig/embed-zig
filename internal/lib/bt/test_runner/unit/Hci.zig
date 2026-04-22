const hci_root = @import("../../Hci.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return hci_root.TestRunner(lib);
}
