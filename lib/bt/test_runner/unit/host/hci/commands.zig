const hci_commands = @import("../../../../host/hci/commands.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return hci_commands.TestRunner(lib);
}
