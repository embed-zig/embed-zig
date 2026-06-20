pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/kcp",
    .filter = "thirdparty/kcp/unit",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const kcp = @import("kcp");

test "thirdparty/kcp/unit" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .kcp_unit);
    defer t.deinit();
    t.run("kcp", kcp.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
