pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/nfc",
    .filter = "embed/nfc/unit/std",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");
const nfc = embed.nfc;

test "embed/nfc/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .nfc);
    defer t.deinit();

    t.run("embed/nfc/unit/std", nfc.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
