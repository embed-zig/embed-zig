const glib = @import("glib");

const peripheral_api = @import("../../Peripheral.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return peripheral_api.TestRunner(lib);
}
