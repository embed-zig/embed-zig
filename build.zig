const std = @import("std");
const Tests = @import("build/Tests.zig");

const lib_embed = @import("build/lib/embed.zig");
const lib_integration = @import("build/lib/integration.zig");
const lib_testing = @import("build/lib/testing.zig");
const lib_context = @import("build/lib/context.zig");
const lib_sync = @import("build/lib/sync.zig");
const lib_io = @import("build/lib/io.zig");
const lib_drivers = @import("build/lib/drivers.zig");
const lib_net = @import("build/lib/net.zig");
const lib_mime = @import("build/lib/mime.zig");
const lib_bt = @import("build/lib/bt.zig");
const lib_motion = @import("build/lib/motion.zig");
const lib_wifi = @import("build/lib/wifi.zig");
const lib_ledstrip = @import("build/lib/ledstrip.zig");
const lib_embed_std = @import("build/lib/embed_std.zig");
const lib_zux = @import("build/lib/zux.zig");

const pkg_core_bluetooth = @import("build/pkg/core_bluetooth.zig");
const pkg_core_wlan = @import("build/pkg/core_wlan.zig");
const pkg_ogg = @import("build/pkg/ogg.zig");
const pkg_stb_truetype = @import("build/pkg/stb_truetype.zig");
const pkg_opus = @import("build/pkg/opus.zig");
const pkg_lvgl = @import("build/pkg/lvgl.zig");
const pkg_portaudio = @import("build/pkg/portaudio.zig");
const Libraries = struct {
    pub const embed = lib_embed;
    pub const integration = lib_integration;
    pub const testing = lib_testing;
    pub const context = lib_context;
    pub const sync = lib_sync;
    pub const io = lib_io;
    pub const drivers = lib_drivers;
    pub const net = lib_net;
    pub const mime = lib_mime;
    pub const bt = lib_bt;
    pub const motion = lib_motion;
    pub const wifi = lib_wifi;
    pub const ledstrip = lib_ledstrip;
    pub const embed_std = lib_embed_std;
    pub const zux = lib_zux;
};

const Packages = struct {
    pub const core_bluetooth = pkg_core_bluetooth;
    pub const core_wlan = pkg_core_wlan;
    pub const ogg = pkg_ogg;
    pub const stb_truetype = pkg_stb_truetype;
    pub const opus = pkg_opus;
    pub const lvgl = pkg_lvgl;
    pub const portaudio = pkg_portaudio;
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_all = b.option(bool, "all", "Enable all optional packages") orelse false;

    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        @field(Libraries, decl.name).create(b, target, optimize);
    }

    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        if (build_all or (b.option(bool, decl.name, decl.name) orelse false)) {
            @field(Packages, decl.name).create(b, target, optimize);
        }
    }

    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        @field(Libraries, decl.name).link(b);
    }
    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        if (b.modules.get(decl.name) != null) {
            @field(Packages, decl.name).link(b);
        }
    }

    const tests = Tests.create(b);
    tests.addTest(b, "embed", null);
    tests.addTest(b, "embed_std", null);
    tests.addTest(b, "io", null);
    tests.addTest(b, "drivers", null);
    tests.addTest(b, "net", null);
    tests.addTest(b, "mime", null);
    tests.addTest(b, "bt", null);
    tests.addTest(b, "motion", null);
    tests.addTest(b, "wifi", null);
    tests.addTest(b, "ledstrip", null);
    tests.addTest(b, "sync", null);
    tests.addTest(b, "context", null);
    tests.addTest(b, "testing", null);
    tests.addTest(b, "integration", null);
    tests.addTest(b, "zux", lib_zux.linkTest);

    if (b.modules.get("core_bluetooth") != null) tests.addTest(b, "core_bluetooth", null);
    if (b.modules.get("core_wlan") != null) tests.addTest(b, "core_wlan", null);
    if (b.modules.get("ogg") != null) tests.addTest(b, "ogg", pkg_ogg.linkTest);
    if (b.modules.get("stb_truetype") != null) tests.addTest(b, "stb_truetype", pkg_stb_truetype.linkTest);
    if (b.modules.get("opus") != null) tests.addTest(b, "opus", pkg_opus.linkTest);
    if (b.modules.get("lvgl") != null) tests.addTest(b, "lvgl", pkg_lvgl.linkTest);
    if (b.modules.get("portaudio") != null) tests.addTest(b, "portaudio", pkg_portaudio.linkTest);
}
