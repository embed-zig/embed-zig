const testing_api = @import("testing");
const wire = @import("../../ntp/wire.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return wire.TestRunner(lib);
}
