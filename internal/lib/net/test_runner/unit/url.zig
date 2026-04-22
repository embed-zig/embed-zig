const testing_api = @import("testing");
const url = @import("../../url.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return url.TestRunner(lib);
}
