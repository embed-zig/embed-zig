pub fn make(comptime lib: type) @import("testing").TestRunner {
    return @import("test_utils/scenario.zig").makeInt16Scenario(lib, 24_000, 1, 1);
}
