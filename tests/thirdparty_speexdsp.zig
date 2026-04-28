pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/speexdsp",
    .labels = &.{ "integration", "unit" },
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const speexdsp = @import("speexdsp");

test "thirdparty/speexdsp/unit/imports" {
    _ = speexdsp.EchoState;
    _ = speexdsp.PreprocessState;
    _ = speexdsp.Resampler;
}

test "thirdparty/speexdsp/unit/root_surface_exposes_phase1_wrappers" {
    const std = @import("std");
    try std.testing.expect(@sizeOf(speexdsp.Sample) == 2);
    try std.testing.expect(speexdsp.resampler_quality_min <= speexdsp.resampler_quality_default);
    try std.testing.expect(speexdsp.resampler_quality_default <= speexdsp.resampler_quality_max);
}

test "thirdparty/speexdsp/unit/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .speexdsp_unit_std);
    defer t.deinit();
    t.run("unit", speexdsp.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/speexdsp/unit/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .speexdsp_unit_embed);
    defer t.deinit();
    t.run("unit", speexdsp.test_runner.unit.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/speexdsp/integration/std" {
    var t = glib.testing.T.new(gstd.runtime.std, .speexdsp_integration_std);
    defer t.deinit();
    t.run("integration", speexdsp.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}

test "thirdparty/speexdsp/integration/embed_std" {
    var t = glib.testing.T.new(gstd.runtime.std, .speexdsp_integration_embed);
    defer t.deinit();
    t.run("integration", speexdsp.test_runner.integration.make(gstd.runtime));
    if (!t.wait()) return error.TestFailed;
}
