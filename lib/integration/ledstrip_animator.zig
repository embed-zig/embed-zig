const testing_api = @import("testing");

test "ledstrip/integration_tests/std" {
    const std = @import("std");
    const ledstrip = @import("../ledstrip.zig");

    var t = testing_api.T.new(std, .std);
    defer t.deinit();

    t.timeout(10 * std.time.ns_per_s);
    t.run("ledstrip/animator", ledstrip.test_runner.animator.make(std));
    if (!t.wait()) return error.TestFailed;
}
