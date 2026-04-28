pub const meta = .{
    .source_file = sourceFile(),
    .module = "glib/crypto",
    .labels = &.{"unit"},
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "glib/crypto/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, .crypto);
    defer t.deinit();

    t.run("glib/crypto/unit/gstd", glib.crypto.test_runner.unit.make(gstd.runtime.std));
    if (!t.wait()) return error.TestFailed;
}
