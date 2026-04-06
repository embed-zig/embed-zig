const mocker_mod = @import("../../../mocker/Hci.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return mocker_mod.TestRunner(lib);
}
