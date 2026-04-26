const glib = @import("glib");

const host_peripheral = @import("../../../host/Peripheral.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return host_peripheral.TestRunner(lib);
}
