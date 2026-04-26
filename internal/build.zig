const std = @import("std");
const build_tests = @import("build/tests.zig");

const lib_drivers = @import("build/lib/drivers.zig");
const lib_bt = @import("build/lib/bt.zig");
const lib_motion = @import("build/lib/motion.zig");
const lib_audio = @import("build/lib/audio.zig");
const lib_ledstrip = @import("build/lib/ledstrip.zig");
const lib_zux = @import("build/lib/zux.zig");

const Packages = struct {};

const Libraries = struct {
    pub const drivers = lib_drivers;
    pub const bt = lib_bt;
    pub const motion = lib_motion;
    pub const audio = lib_audio;
    pub const ledstrip = lib_ledstrip;
    pub const zux = lib_zux;
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
        linkLibrary(@field(Libraries, decl.name), b, target, optimize);
    }

    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        if (b.modules.get(decl.name) != null) {
            linkLibrary(@field(Packages, decl.name), b, target, optimize);
        }
    }

    build_tests.create(b, target, optimize, Libraries, Packages);
}

fn linkLibrary(
    comptime lib: type,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const params_len = @typeInfo(@TypeOf(lib.link)).@"fn".params.len;
    if (params_len == 1) {
        lib.link(b);
    } else if (params_len == 3) {
        lib.link(b, target, optimize);
    } else {
        @compileError("library link function must accept (b) or (b, target, optimize)");
    }
}
