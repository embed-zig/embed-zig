const glib = @import("glib");
pub fn make(comptime grt: type) glib.testing.TestRunner {
    return @import("test_utils/scenario.zig").makeInt16Scenario(grt, 16_000, 1, 2);
}
