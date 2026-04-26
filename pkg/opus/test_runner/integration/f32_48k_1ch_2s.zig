pub fn make(comptime lib: type) @import("testing").TestRunner {
    return @import("test_utils/scenario.zig").makeFloatScenario(lib, 48_000, 1, 2);
}
