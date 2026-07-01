const std = @import("std");

const lvgl_common = @import("build/pkg/lvgl_common.zig");
const pkg_core_bluetooth = @import("build/pkg/core_bluetooth.zig");
const pkg_core_wlan = @import("build/pkg/core_wlan.zig");
const pkg_lvgl = @import("build/pkg/lvgl.zig");
const pkg_lvgl_osal = @import("build/pkg/lvgl_osal.zig");
const pkg_kcp = @import("build/pkg/kcp.zig");
const pkg_mbedtls = @import("build/pkg/mbedtls.zig");
const pkg_opus = @import("build/pkg/opus.zig");
const pkg_portaudio = @import("build/pkg/portaudio.zig");
const pkg_speexdsp = @import("build/pkg/speexdsp.zig");
const pkg_stb_truetype = @import("build/pkg/stb_truetype.zig");

pub const lvgl = pkg_lvgl;
pub const lvgl_osal = pkg_lvgl_osal;

const Packages = struct {
    pub const core_bluetooth = pkg_core_bluetooth;
    pub const core_wlan = pkg_core_wlan;
    pub const kcp = pkg_kcp;
    pub const lvgl = pkg_lvgl;
    pub const lvgl_osal = pkg_lvgl_osal;
    pub const mbedtls = pkg_mbedtls;
    pub const opus = pkg_opus;
    pub const portaudio = pkg_portaudio;
    pub const speexdsp = pkg_speexdsp;
    pub const stb_truetype = pkg_stb_truetype;
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sysroot = b.option([]const u8, "sysroot", "C sysroot path for cross-target libc headers") orelse "";
    if (sysroot.len != 0) b.sysroot = sysroot;
    const lvgl_c_sysroot = b.option(
        []const u8,
        "lvgl_c_sysroot",
        "Optional C sysroot used when compiling LVGL for freestanding embedded targets",
    ) orelse "";
    const lvgl_c_short_enums = b.option(
        bool,
        "lvgl_c_short_enums",
        "Compile LVGL C sources with -fshort-enums to match embedded GCC ABI settings",
    ) orelse false;
    lvgl_common.configure(b, lvgl_c_sysroot, lvgl_c_short_enums);

    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        @field(Packages, decl.name).create(b, target, optimize);
    }
    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        @field(Packages, decl.name).link(b, target, optimize);
    }
}
