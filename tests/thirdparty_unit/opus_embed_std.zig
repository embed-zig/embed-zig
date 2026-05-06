pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/opus",
    .filter = "thirdparty/opus/unit/embed_std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const opus = @import("opus");

test "thirdparty/opus/unit/embed_std" {
    _ = @import("../utils/thirdparty_opus_osal.zig");

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .opus_unit_embed_std);
    defer t.deinit();
    t.run("unit", opus.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
