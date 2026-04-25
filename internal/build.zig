const std = @import("std");
const build_tests = @import("build/tests.zig");

const lib_stdz = @import("build/lib/stdz.zig");
const lib_testing = @import("build/lib/testing.zig");
const lib_context = @import("build/lib/context.zig");
const lib_sync = @import("build/lib/sync.zig");
const lib_io = @import("build/lib/io.zig");
const lib_drivers = @import("build/lib/drivers.zig");
const lib_net = @import("build/lib/net.zig");
const lib_mime = @import("build/lib/mime.zig");
const lib_bt = @import("build/lib/bt.zig");
const lib_motion = @import("build/lib/motion.zig");
const lib_audio = @import("build/lib/audio.zig");
const lib_ledstrip = @import("build/lib/ledstrip.zig");
const lib_embed_std = @import("build/lib/embed_std.zig");
const lib_zux = @import("build/lib/zux.zig");
const lib_runtime = @import("build/lib/runtime.zig");

const Packages = struct {};

const Libraries = struct {
    pub const stdz = lib_stdz;
    pub const testing = lib_testing;
    pub const context = lib_context;
    pub const sync = lib_sync;
    pub const io = lib_io;
    pub const drivers = lib_drivers;
    pub const net = lib_net;
    pub const mime = lib_mime;
    pub const bt = lib_bt;
    pub const motion = lib_motion;
    pub const audio = lib_audio;
    pub const ledstrip = lib_ledstrip;
    pub const embed_std = lib_embed_std;
    pub const zux = lib_zux;
    pub const runtime = lib_runtime;
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

    build_tests.create(b, target, optimize, Libraries, Packages);
}
