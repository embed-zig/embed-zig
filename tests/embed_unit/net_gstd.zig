pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/net",
    .filter = "embed/net/unit/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");
const net = embed.net;

test "embed/net/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .net);
    defer t.deinit();

    t.run("embed/net/unit/gstd", net.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
