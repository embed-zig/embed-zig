const testing_api = @import("testing");
const fd = @import("../../fd.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return fd.TestRunner(lib);
}
