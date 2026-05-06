pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/lvgl",
    .filter = "thirdparty/lvgl/unit",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const lvgl = @import("lvgl");

test "thirdparty/lvgl/unit" {
    _ = @import("../utils/thirdparty_lvgl_osal.zig");

    const std = @import("std");
    var t = glib.testing.T.new(std, gstd.runtime.time, .lvgl_unit);
    defer t.deinit();
    t.run("unit", lvgl.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
