pub const meta = .{
    .source_file = sourceFile(),
    .module = "desktop",
    .filter = "desktop/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const desktop = @import("desktop");

test "desktop/unit/gstd" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .embed);
    defer t.deinit();

    t.run("desktop/device/unit/gstd", desktop.device.test_runner.unit.make(gstd.runtime.std));
    t.run("desktop/http/unit/gstd", desktop.http.test_runner.unit.make(gstd.runtime.std));
    t.run("desktop/app/unit/gstd", desktop.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
