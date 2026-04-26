const glib = @import("glib");
pub fn make(comptime grt: type) glib.testing.TestRunner {
    return @import("test_utils/scenario.zig").makeFloatScenario(grt, 48_000, 1, 2);
}
