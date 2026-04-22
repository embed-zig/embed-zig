const peripheral_api = @import("../../Peripheral.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return peripheral_api.TestRunner(lib);
}
