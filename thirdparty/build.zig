const std = @import("std");

const pkg_core_bluetooth = @import("build/pkg/core_bluetooth.zig");
const pkg_core_wlan = @import("build/pkg/core_wlan.zig");
const pkg_lvgl = @import("build/pkg/lvgl.zig");
const pkg_mbedtls = @import("build/pkg/mbedtls.zig");
const pkg_opus = @import("build/pkg/opus.zig");
const pkg_portaudio = @import("build/pkg/portaudio.zig");
const pkg_speexdsp = @import("build/pkg/speexdsp.zig");
const pkg_stb_truetype = @import("build/pkg/stb_truetype.zig");

const Packages = struct {
    pub const core_bluetooth = pkg_core_bluetooth;
    pub const core_wlan = pkg_core_wlan;
    pub const lvgl = pkg_lvgl;
    pub const mbedtls = pkg_mbedtls;
    pub const opus = pkg_opus;
    pub const portaudio = pkg_portaudio;
    pub const speexdsp = pkg_speexdsp;
    pub const stb_truetype = pkg_stb_truetype;
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        @field(Packages, decl.name).create(b, target, optimize);
    }
    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        @field(Packages, decl.name).link(b, target, optimize);
    }
}
