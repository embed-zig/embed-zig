const std = @import("std");

// Re-export build helpers for downstream `@import("esp").idf` users.
pub const idf = @import("lib/idf.zig");

pub const ModuleSources = struct {
    heap: std.Build.LazyPath,
    idf: std.Build.LazyPath,
    embed_adapter: std.Build.LazyPath,
    grt: std.Build.LazyPath,
    esp: std.Build.LazyPath,
};

pub const ModuleConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glib: *std.Build.Module,
    embed_core: *std.Build.Module,
    sources: ModuleSources,
};

pub const Modules = struct {
    esp: *std.Build.Module,
    embed_adapter: *std.Build.Module,
};

pub fn moduleSources(b: *std.Build, package_root: []const u8) ModuleSources {
    return .{
        .heap = b.path(sourcePath(b, package_root, "lib/heap/heap.zig")),
        .idf = b.path(sourcePath(b, package_root, "lib/idf.zig")),
        .embed_adapter = b.path(sourcePath(b, package_root, "lib/embed.zig")),
        .grt = b.path(sourcePath(b, package_root, "lib/grt.zig")),
        .esp = b.path(sourcePath(b, package_root, "lib/esp.zig")),
    };
}

pub fn createModules(b: *std.Build, config: ModuleConfig) Modules {
    const heap_module = b.createModule(.{
        .root_source_file = config.sources.heap,
        .target = config.target,
        .optimize = config.optimize,
        .imports = &.{
            .{ .name = "glib", .module = config.glib },
        },
    });
    const idf_module = b.createModule(.{
        .root_source_file = config.sources.idf,
        .target = config.target,
        .optimize = config.optimize,
    });
    const embed_adapter_module = b.createModule(.{
        .root_source_file = config.sources.embed_adapter,
        .target = config.target,
        .optimize = config.optimize,
        .imports = &.{
            .{ .name = "embed_core", .module = config.embed_core },
        },
    });
    const grt_module = b.createModule(.{
        .root_source_file = config.sources.grt,
        .target = config.target,
        .optimize = config.optimize,
        .imports = &.{
            .{ .name = "glib", .module = config.glib },
            .{ .name = "esp_heap", .module = heap_module },
        },
    });
    const esp_module = b.createModule(.{
        .root_source_file = config.sources.esp,
        .target = config.target,
        .optimize = config.optimize,
        .imports = &.{
            .{ .name = "glib", .module = config.glib },
            .{ .name = "esp_grt", .module = grt_module },
            .{ .name = "esp_heap", .module = heap_module },
            .{ .name = "esp_idf", .module = idf_module },
            .{ .name = "esp_embed", .module = embed_adapter_module },
        },
    });
    embed_adapter_module.addImport("esp", esp_module);
    return .{
        .esp = esp_module,
        .embed_adapter = embed_adapter_module,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_module = glib_dep.module("glib");
    const embed_module = embed_dep.module("embed");
    const modules = createModules(b, .{
        .target = target,
        .optimize = optimize,
        .glib = glib_module,
        .embed_core = embed_module,
        .sources = moduleSources(b, ""),
    });
    b.modules.put("esp_embed", modules.embed_adapter) catch @panic("OOM");
    b.modules.put("esp", modules.esp) catch @panic("OOM");

    const idf_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/idf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_idf_tests = b.addRunArtifact(idf_tests);
    const test_step = b.step("test", "Run IDF build-system tests");
    test_step.dependOn(&run_idf_tests.step);
}

fn sourcePath(b: *std.Build, package_root: []const u8, rel_path: []const u8) []const u8 {
    if (package_root.len == 0) return rel_path;
    return b.fmt("{s}/{s}", .{ package_root, rel_path });
}
