const std = @import("std");

const lib_audio = @import("audio.zig");
const lib_bt = @import("bt.zig");
const lib_drivers = @import("drivers.zig");
const lib_ledstrip = @import("ledstrip.zig");
const lib_motion = @import("motion.zig");
const lib_zux = @import("zux.zig");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const audio = lib_audio.create(b, target, optimize);
    const bt = lib_bt.create(b, target, optimize);
    const drivers = lib_drivers.create(b, target, optimize);
    const ledstrip = lib_ledstrip.create(b, target, optimize);
    const motion = lib_motion.create(b, target, optimize);
    const zux = lib_zux.create(b, target, optimize);

    lib_audio.link(b, target, optimize, audio);
    lib_bt.link(b, target, optimize, bt);
    lib_drivers.link(b, target, optimize, drivers);
    lib_ledstrip.link(b, target, optimize, ledstrip);
    lib_motion.link(b, target, optimize, motion);
    lib_zux.link(b, target, optimize, zux, .{
        .motion = motion,
        .bt = bt,
        .drivers = drivers,
        .ledstrip = ledstrip,
    });

    const mod = createModule(b, target, optimize, "embed.zig");
    mod.addImport("audio", audio);
    mod.addImport("bt", bt);
    mod.addImport("drivers", drivers);
    mod.addImport("ledstrip", ledstrip);
    mod.addImport("motion", motion);
    mod.addImport("zux", zux);
    b.modules.put("embed", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    _ = b;
}

pub fn createModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime root_source_file: []const u8,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
}
