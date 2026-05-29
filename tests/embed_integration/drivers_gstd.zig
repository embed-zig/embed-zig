pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/drivers",
    .filter = "embed/drivers/integration/gstd",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");
const bt = embed.bt;
const ledstrip = embed.ledstrip;
const drivers = embed.drivers;
const motion = embed.motion;
const audio = embed.audio;
const zux = embed.zux;

test "embed/drivers/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .drivers);
    defer t.deinit();

    t.run("embed/drivers/integration/gstd", drivers.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
