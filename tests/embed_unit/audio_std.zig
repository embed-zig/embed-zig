pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/audio",
    .filter = "embed/audio/unit/std",
    .label = .unit,
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

test "embed/audio/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .audio);
    defer t.deinit();

    t.run("embed/audio/unit/std", audio.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
