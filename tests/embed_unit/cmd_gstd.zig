pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/cmd",
    .filter = "embed/cmd/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

test "embed/cmd/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .cmd);
    defer t.deinit();

    t.run("embed/cmd/unit/gstd", embed.cmd.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
