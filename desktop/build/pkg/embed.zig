const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });

    _ = createEmbedModule(b, embed_dep, target, optimize, "ledstrip", "lib/ledstrip.zig", &.{
        .{ .name = "embed", .module = embed_dep.module("embed") },
        .{ .name = "testing", .module = embed_dep.module("testing") },
    });
    _ = createEmbedModule(b, embed_dep, target, optimize, "drivers", "lib/drivers.zig", &.{
        .{ .name = "embed", .module = embed_dep.module("embed") },
        .{ .name = "net", .module = embed_dep.module("net") },
        .{ .name = "testing", .module = embed_dep.module("testing") },
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("embed", embed_dep.module("embed"));
    mod.addImport("context", embed_dep.module("context"));
    mod.addImport("net", embed_dep.module("net"));
    mod.addImport("sync", embed_dep.module("sync"));
    mod.addImport("drivers", b.modules.get("drivers") orelse @panic("drivers module missing"));
    mod.addImport("ledstrip", b.modules.get("ledstrip") orelse @panic("ledstrip module missing"));
    mod.addImport("testing", embed_dep.module("testing"));
    mod.addImport("integration", embed_dep.module("integration"));
    mod.addImport("embed_std", embed_dep.module("embed_std"));

    b.modules.put("dep", mod) catch @panic("OOM");
}

const ImportSpec = struct {
    name: []const u8,
    module: *std.Build.Module,
};

fn createEmbedModule(
    b: *std.Build,
    embed_dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source_path: []const u8,
    imports: []const ImportSpec,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = embed_dep.path(source_path),
        .target = target,
        .optimize = optimize,
    });
    for (imports) |import_spec| {
        mod.addImport(import_spec.name, import_spec.module);
    }
    b.modules.put(name, mod) catch @panic("OOM");
    return mod;
}

pub fn link(_: *std.Build) void {}

pub fn linkTest(_: *std.Build, _: *std.Build.Step.Compile) void {}
