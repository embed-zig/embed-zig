const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/zux.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("zux", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("zux requires embed");
    const motion = b.modules.get("motion") orelse @panic("zux requires motion");
    const net = b.modules.get("net") orelse @panic("zux requires net");
    const sync = b.modules.get("sync") orelse @panic("zux requires sync");
    const bt = b.modules.get("bt") orelse @panic("zux requires bt");
    const ledstrip = b.modules.get("ledstrip") orelse @panic("zux requires ledstrip");
    const embed_std = b.modules.get("embed_std") orelse @panic("zux requires embed_std");
    const testing = b.modules.get("testing") orelse @panic("zux requires testing");
    const mod = b.modules.get("zux") orelse @panic("zux module missing");
    mod.addImport("embed", embed);
    mod.addImport("motion", motion);
    mod.addImport("net", net);
    mod.addImport("sync", sync);
    mod.addImport("bt", bt);
    mod.addImport("ledstrip", ledstrip);
    mod.addImport("embed_std", embed_std);
    mod.addImport("testing", testing);
}

pub fn linkTest(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const embed_std = b.modules.get("embed_std") orelse @panic("zux tests require embed_std");
    compile.root_module.addImport("embed_std", embed_std);
}
