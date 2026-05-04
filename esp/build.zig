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
    const glib_module = glib_dep.module("glib");
    const heap_module = b.addModule("esp_heap", .{
        .root_source_file = b.path("lib/heap/heap.zig"),
        .imports = &.{
            .{ .name = "glib", .module = glib_module },
        },
    });
    const grt_module = b.addModule("esp_grt", .{
        .root_source_file = b.path("lib/grt.zig"),
        .imports = &.{
            .{ .name = "glib", .module = glib_module },
            .{ .name = "esp_heap", .module = heap_module },
        },
    });
    const idf_module = b.addModule("esp_idf", .{
        .root_source_file = b.path("lib/idf.zig"),
    });
    _ = b.addModule("esp", .{
        .root_source_file = b.path("lib/esp.zig"),
        .imports = &.{
            .{ .name = "glib", .module = glib_module },
            .{ .name = "esp_grt", .module = grt_module },
            .{ .name = "esp_heap", .module = heap_module },
            .{ .name = "esp_idf", .module = idf_module },
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
