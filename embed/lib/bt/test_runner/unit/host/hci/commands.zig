const glib = @import("glib");

const hci_commands = @import("../../../../host/hci/commands.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return hci_commands.TestRunner(grt);
}
