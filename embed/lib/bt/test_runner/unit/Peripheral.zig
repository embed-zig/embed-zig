const glib = @import("glib");

const peripheral_api = @import("../../Peripheral.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return peripheral_api.TestRunner(grt);
}
