pub const meta = .{
    .source_file = sourceFile(),
    .module = "thirdparty/speexdsp",
    .filter = "thirdparty/speexdsp/unit/root_surface_exposes_phase1_wrappers",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");
const speexdsp = @import("speexdsp");

test "thirdparty/speexdsp/unit/root_surface_exposes_phase1_wrappers" {
    const std = @import("std");
    try std.testing.expect(@sizeOf(speexdsp.Sample) == 2);
    try std.testing.expect(speexdsp.resampler_quality_min <= speexdsp.resampler_quality_default);
    try std.testing.expect(speexdsp.resampler_quality_default <= speexdsp.resampler_quality_max);
}
