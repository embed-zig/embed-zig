pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/bt",
    .labels = &.{ "integration", "unit" },
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

test "embed/bt/unit/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .bt);
    defer t.deinit();

    t.run("embed/bt/unit/std", bt.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "embed/bt/unit/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .bt);
    defer t.deinit();

    t.run("embed/bt/unit/gstd", bt.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "embed/bt/integration/std" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .bt);
    defer t.deinit();
    t.timeout(60 * glib.time.duration.Second);

    t.run("embed/bt/integration/std", bt.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "embed/bt/integration/gstd" {
    const std = @import("std");

    std.testing.log_level = .info;

    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .bt);
    defer t.deinit();
    t.timeout(60 * glib.time.duration.Second);

    t.run("embed/bt/integration/gstd", bt.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
