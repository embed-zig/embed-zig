pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/stdz",
    .filter = "glib/stdz/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/stdz/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, gstd.runtime.time, .stdz);
    defer t.deinit();
    t.timeout(20 * glib.time.duration.Second);
    try std.testing.expect(!@hasDecl(glib.std, "time"));

    t.run("glib/stdz/unit/std", glib.std.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}
