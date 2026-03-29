//! LVGL API smoke integration test entrypoint.

const std = @import("std");
const testing_mod = @import("testing");
const lvgl_runner = @import("../test_runner/lvgl.zig");

test "lvgl/integration_tests/lvgl" {
    var t = testing_mod.T.new(std, .lvgl_integration);
    defer t.deinit();

    t.run("lvgl", lvgl_runner.make(std));
    if (!t.wait()) return error.TestFailed;
}
