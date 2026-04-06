const host_peripheral = @import("../../../host/Peripheral.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return host_peripheral.TestRunner(lib);
}
