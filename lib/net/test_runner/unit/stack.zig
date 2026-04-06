const testing_api = @import("testing");
const Stack = @import("../../stack/Stack.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return Stack.TestRunner(lib);
}
