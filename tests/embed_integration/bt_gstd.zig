pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/bt",
    .filter = "embed/bt/integration/gstd",
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

test "embed/bt/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    // The BT integration pair/xfer runners share in-process mock host state.
    const TestStd = glib.testing.std.make(gstd.runtime.std, .{ .isolate_thread = false });
    var t = glib.testing.T.new(TestStd, gstd.runtime.time, .bt);
    defer t.deinit();
    t.timeout(60 * glib.time.duration.Second);

    t.run("embed/bt/integration/gstd", bt.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
