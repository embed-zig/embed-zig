pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/stdz",
    .labels = &.{"unit"},
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/stdz/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(std, .stdz);
    defer t.deinit();
    t.timeout(20 * std.time.ns_per_s);

    t.run("glib/stdz/unit/std", glib.std.test_runner.unit.make(std));
    if (!t.wait()) return error.TestFailed;
}

test "glib/stdz/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .stdz);
    defer t.deinit();
    t.timeout(20 * gstd.runtime.std.time.ns_per_s);

    t.run("glib/stdz/unit/gstd", glib.std.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
