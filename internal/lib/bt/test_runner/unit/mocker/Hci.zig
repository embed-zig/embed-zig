const glib = @import("glib");

const mocker_mod = @import("../../../mocker/Hci.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return mocker_mod.TestRunner(lib);
}
