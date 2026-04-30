pub const meta = .{
    .source_file = sourceFile(),
    .module = "desktop",
    .filter = "desktop/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const desktop = @import("desktop");

test "desktop/unit/std" {
    const std = @import("std");

    var t = glib.testing.T.new(std, gstd.runtime.time, .std);
    defer t.deinit();

    t.run("desktop/device/unit/std", desktop.device.test_runner.unit.make(std));
    t.run("desktop/http/unit/std", desktop.http.test_runner.unit.make(std));
    t.run("desktop/app/unit/std", desktop.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}
