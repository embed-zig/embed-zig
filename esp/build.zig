const std = @import("std");

// Re-export build helpers for downstream `@import("esp").idf`.
pub const idf = @import("lib/idf.zig");

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
    const heap_module = b.createModule(.{
        .root_source_file = b.path("lib/heap/heap.zig"),
        .imports = &.{
            .{ .name = "glib", .module = glib_module },
        },
    });
    const idf_module = b.createModule(.{
        .root_source_file = b.path("lib/idf.zig"),
    });
    const embed_adapter_module = b.createModule(.{
        .root_source_file = b.path("lib/embed.zig"),
        .imports = &.{
            .{ .name = "embed", .module = embed_module },
        },
    });
    const grt_module = b.createModule(.{
        .root_source_file = b.path("lib/grt.zig"),
        .imports = &.{
            .{ .name = "glib", .module = glib_module },
            .{ .name = "esp_heap", .module = heap_module },
        },
    });
    _ = b.addModule("esp", .{
        .root_source_file = b.path("lib/esp.zig"),
        .imports = &.{
            .{ .name = "glib", .module = glib_module },
            .{ .name = "esp_grt", .module = grt_module },
            .{ .name = "esp_heap", .module = heap_module },
            .{ .name = "esp_idf", .module = idf_module },
            .{ .name = "esp_embed", .module = embed_adapter_module },
        },
    });

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
