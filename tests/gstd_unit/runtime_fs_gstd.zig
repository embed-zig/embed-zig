pub const meta = .{
    .source_file = sourceFile(),
    .module = "gstd/runtime",
    .filter = "gstd/runtime/unit/fs/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "gstd/runtime/unit/fs/gstd" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .fs);
    defer t.deinit();

    t.run("gstd/fs", gstd.fs.TestRunner(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
