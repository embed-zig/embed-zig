const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_stdrt_dep = b.dependency("glib_stdrt", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_mod = b.createModule(.{
        .root_source_file = glib_dep.path("glib.zig"),
        .target = target,
        .optimize = optimize,
    });
    glib_mod.addImport("stdz", b.modules.get("stdz") orelse @panic("embed_std requires stdz"));
    glib_mod.addImport("testing", b.modules.get("testing") orelse @panic("embed_std requires testing"));
    glib_mod.addImport("context", b.modules.get("context") orelse @panic("embed_std requires context"));
    glib_mod.addImport("sync", b.modules.get("sync") orelse @panic("embed_std requires sync"));
    glib_mod.addImport("io", b.modules.get("io") orelse @panic("embed_std requires io"));
    glib_mod.addImport("mime", b.modules.get("mime") orelse @panic("embed_std requires mime"));
    glib_mod.addImport("net", b.modules.get("net") orelse @panic("embed_std requires net"));

    const mod = b.createModule(.{
        .root_source_file = glib_stdrt_dep.path("glib_stdrt.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("glib", glib_mod);
    b.modules.put("embed_std", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    _ = b;
}
