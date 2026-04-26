const std = @import("std");
const build_tests = @import("build/tests.zig");

const lib_embed = @import("build/lib/embed.zig");

const Libraries = struct {
    pub const embed = lib_embed;
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        @field(Libraries, decl.name).create(b, target, optimize);
    }

    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        linkLibrary(@field(Libraries, decl.name), b, target, optimize);
    }

    build_tests.create(b, target, optimize, Libraries);
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
