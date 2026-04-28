pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/opus",
    .labels = &.{ "integration", "unit" },
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const opus = @import("opus");

test "thirdparty/opus/unit/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .opus_unit_std);
    defer t.deinit();
    t.run("unit", opus.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/opus/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .opus_unit_embed_std);
    defer t.deinit();
    t.run("unit", opus.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/opus/integration/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .opus_integration_std);
    defer t.deinit();
    t.run("integration", opus.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/opus/integration/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .opus_integration_embed_std);
    defer t.deinit();
    t.run("integration", opus.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
