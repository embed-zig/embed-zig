const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("runtime", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const audio = b.modules.get("audio") orelse @panic("runtime requires audio");
    const bt = b.modules.get("bt") orelse @panic("runtime requires bt");
    const context = b.modules.get("context") orelse @panic("runtime requires context");
    const drivers = b.modules.get("drivers") orelse @panic("runtime requires drivers");
    const io = b.modules.get("io") orelse @panic("runtime requires io");
    const ledstrip = b.modules.get("ledstrip") orelse @panic("runtime requires ledstrip");
    const mime = b.modules.get("mime") orelse @panic("runtime requires mime");
    const motion = b.modules.get("motion") orelse @panic("runtime requires motion");
    const net = b.modules.get("net") orelse @panic("runtime requires net");
    const stdz = b.modules.get("stdz") orelse @panic("runtime requires stdz");
    const sync = b.modules.get("sync") orelse @panic("runtime requires sync");
    const testing = b.modules.get("testing") orelse @panic("runtime requires testing");
    const zux = b.modules.get("zux") orelse @panic("runtime requires zux");
    const mod = b.modules.get("runtime") orelse @panic("runtime module missing");
    mod.addImport("audio", audio);
    mod.addImport("bt", bt);
    mod.addImport("context", context);
    mod.addImport("drivers", drivers);
    mod.addImport("io", io);
    mod.addImport("ledstrip", ledstrip);
    mod.addImport("mime", mime);
    mod.addImport("motion", motion);
    mod.addImport("net", net);
    mod.addImport("stdz", stdz);
    mod.addImport("sync", sync);
    mod.addImport("testing", testing);
    mod.addImport("zux", zux);
}
