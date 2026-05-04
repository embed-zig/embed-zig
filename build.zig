const std = @import("std");
const build_modules = @import("build/modules.zig");
const build_tests = @import("tests/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const desktop_dep = b.dependency("desktop", .{
        .target = target,
        .optimize = optimize,
    });
    const apps_dep = b.dependency("apps", .{
        .target = target,
        .optimize = optimize,
    });
    const esp_dep = b.dependency("esp", .{
        .target = target,
        .optimize = optimize,
    });
    const openapi_codegen_dep = b.dependency("openapi_codegen", .{
        .target = target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = target,
        .optimize = optimize,
    });
    const glib = glib_dep.module("glib");
    const gstd = gstd_dep.module("gstd");
    const embed = embed_dep.module("embed");
    const openapi = openapi_codegen_dep.module("openapi");
    const codegen = openapi_codegen_dep.module("codegen");
    const desktop = desktop_dep.module("desktop");
    const esp = esp_dep.module("esp");

    b.modules.put("glib", glib) catch @panic("OOM");
    b.modules.put("gstd", gstd) catch @panic("OOM");
    b.modules.put("embed", embed) catch @panic("OOM");
    b.modules.put("openapi", openapi) catch @panic("OOM");
    b.modules.put("codegen", codegen) catch @panic("OOM");
    b.modules.put("openapi-codegen", codegen) catch @panic("OOM");
    b.modules.put("desktop", desktop) catch @panic("OOM");
    b.modules.put("esp", esp) catch @panic("OOM");
    for (build_modules.thirdparty_modules) |module_spec| {
        b.modules.put(module_spec.export_name, thirdparty_dep.module(module_spec.dependency_module_name)) catch @panic("OOM");
    }
    for (build_modules.apps_modules) |module_spec| {
        b.modules.put(module_spec.export_name, apps_dep.module(module_spec.dependency_module_name)) catch @panic("OOM");
    }

    build_tests.create(b, target, optimize);
}
