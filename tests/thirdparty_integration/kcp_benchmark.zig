pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/kcp",
    .filter = "thirdparty/kcp/benchmark",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const kcp = @import("kcp");

test "thirdparty/kcp/benchmark" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .kcp_benchmark);
    defer t.deinit();
    t.run("kcp", kcp.test_runner.benchmark.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
