const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("integration", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const audio = b.modules.get("audio") orelse @panic("integration requires audio");
    const embed = b.modules.get("embed") orelse @panic("integration requires embed");
    const context = b.modules.get("context") orelse @panic("integration requires context");
    const testing = b.modules.get("testing") orelse @panic("integration requires testing");
    const embed_std = b.modules.get("embed_std") orelse @panic("integration requires embed_std");
    const sync = b.modules.get("sync") orelse @panic("integration requires sync");
    const net = b.modules.get("net") orelse @panic("integration requires net");
    const bt = b.modules.get("bt") orelse @panic("integration requires bt");
    const mod = b.modules.get("integration") orelse @panic("integration module missing");
    mod.addImport("audio", audio);
    mod.addImport("embed", embed);
    mod.addImport("context", context);
    mod.addImport("testing", testing);
    mod.addImport("embed_std", embed_std);
    mod.addImport("sync", sync);
    mod.addImport("net", net);
    mod.addImport("bt", bt);
}
