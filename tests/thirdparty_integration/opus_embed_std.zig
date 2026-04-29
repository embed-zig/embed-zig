pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/opus",
    .filter = "thirdparty/opus/integration/embed_std",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const opus = @import("opus");

test "thirdparty/opus/integration/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .opus_integration_embed_std);
    defer t.deinit();
    t.run("integration", opus.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
