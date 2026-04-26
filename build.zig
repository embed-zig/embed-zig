const std = @import("std");
const build_tests = @import("build/tests.zig");

const pkg_core_bluetooth = @import("build/pkg/core_bluetooth.zig");
const pkg_core_wlan = @import("build/pkg/core_wlan.zig");
const pkg_opus = @import("build/pkg/opus.zig");
const pkg_lvgl = @import("build/pkg/lvgl.zig");
const pkg_speexdsp = @import("build/pkg/speexdsp.zig");
const pkg_stb_truetype = @import("build/pkg/stb_truetype.zig");
const pkg_portaudio = @import("build/pkg/portaudio.zig");

const Packages = struct {
    pub const core_bluetooth = pkg_core_bluetooth;
    pub const core_wlan = pkg_core_wlan;
    pub const opus = pkg_opus;
    pub const lvgl = pkg_lvgl;
    pub const speexdsp = pkg_speexdsp;
    pub const stb_truetype = pkg_stb_truetype;
    pub const portaudio = pkg_portaudio;
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
    b.modules.put("glib", glib_dep.module("glib")) catch @panic("OOM");
    b.modules.put("gstd", gstd_dep.module("gstd")) catch @panic("OOM");
    b.modules.put("embed", embed_dep.module("embed")) catch @panic("OOM");

    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        @field(Packages, decl.name).create(b, target, optimize);
    }
    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        @field(Packages, decl.name).link(b, target, optimize);
    }

    build_tests.create(b, target, optimize, Packages);
}
