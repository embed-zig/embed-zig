const std = @import("std");
const build_tests = @import("tests/build.zig");

const thirdparty_modules = [_][]const u8{
    "core_bluetooth",
    "core_wlan",
    "lvgl",
    "lvgl_osal",
    "mbedtls",
    "opus",
    "portaudio",
    "speexdsp",
    "stb_truetype",
};

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
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("glib", glib_dep.module("glib")) catch @panic("OOM");
    b.modules.put("gstd", gstd_dep.module("gstd")) catch @panic("OOM");
    b.modules.put("embed", embed_dep.module("embed")) catch @panic("OOM");
    for (thirdparty_modules) |module_name| {
        b.modules.put(module_name, thirdparty_dep.module(module_name)) catch @panic("OOM");
    }

    build_tests.create(b, target, optimize);
}
