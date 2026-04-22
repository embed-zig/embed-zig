const central_api = @import("../../Central.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return central_api.TestRunner(lib);
}
