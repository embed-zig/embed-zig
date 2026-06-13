pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/system",
    .filter = "embed/system/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");
const system = embed.system;

test "embed/system/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .system);
    defer t.deinit();

    t.run("embed/system/unit/std", system.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
