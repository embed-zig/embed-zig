const std = @import("std");

const Lib = struct {
    embed: LibEntry = .{ .path = "lib/embed.zig" },
    io: LibEntry = .{ .path = "lib/io.zig" },
    net: LibEntry = .{ .path = "lib/net.zig" },
    mime: LibEntry = .{ .path = "lib/mime.zig" },
    bt: LibEntry = .{ .path = "lib/bt.zig" },
    sync: LibEntry = .{ .path = "lib/sync.zig" },
    context: LibEntry = .{ .path = "lib/context.zig" },
};

const Pkg = struct {
    core_bluetooth: PkgEntry = .{ .option = "core_bluetooth", .desc = "Enable CoreBluetooth backend (Apple only)" },
};

const Tests = struct {
    embed: TestEntry = .{ .from = .lib },
    io: TestEntry = .{ .from = .lib },
    net: TestEntry = .{ .from = .lib },
    mime: TestEntry = .{ .from = .lib },
    sync: TestEntry = .{ .from = .lib },
    context: TestEntry = .{ .from = .lib },
    core_bluetooth: TestEntry = .{ .from = .pkg, .os = &.{ .macos, .ios, .tvos, .watchos } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var lib = Lib{};
    var pkg = Pkg{};

    createLib(b, target, optimize, &lib);
    createPkg(b, target, optimize, &lib, &pkg);

    inline for (@typeInfo(Pkg).@"struct".fields) |f| {
        const entry = @field(pkg, f.name);
        if (entry.enable) {
            b.modules.put(f.name, entry.mod.?) catch @panic("OOM");
        }
    }

    runTests(b, &lib, &pkg);
}

// ---------------------------------------------------------------------------

const Os = std.Target.Os.Tag;
const host_os = @import("builtin").os.tag;

const PkgEntry = struct { option: []const u8, desc: []const u8, enable: bool = false, mod: ?*std.Build.Module = null };
const LibEntry = struct { path: []const u8, mod: *std.Build.Module = undefined };
const TestEntry = struct {
    from: enum { lib, pkg },
    os: []const Os = &.{},
};

fn createLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lib: *Lib) void {
    inline for (@typeInfo(Lib).@"struct".fields) |f| {
        const entry = &@field(lib, f.name);
        const m = b.createModule(.{
            .root_source_file = b.path(entry.path),
            .target = target,
            .optimize = optimize,
        });
        b.modules.put(f.name, m) catch @panic("OOM");
        entry.mod = m;
    }

    lib.context.mod.addImport("embed", lib.embed.mod);
    lib.io.mod.addImport("embed", lib.embed.mod);
    lib.mime.mod.addImport("embed", lib.embed.mod);
    lib.sync.mod.addImport("context", lib.context.mod);
    lib.net.mod.addImport("sync", lib.sync.mod);
    lib.net.mod.addImport("context", lib.context.mod);
    lib.net.mod.addImport("io", lib.io.mod);
}

fn createPkg(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lib: *const Lib, pkg: *Pkg) void {
    inline for (@typeInfo(Pkg).@"struct".fields) |f| {
        const entry = &@field(pkg, f.name);
        entry.enable = b.option(bool, entry.option, entry.desc) orelse entry.enable;
    }

    const cb = b.createModule(.{
        .root_source_file = b.path("pkg/core_bluetooth/src/core_bluetooth.zig"),
        .target = target,
        .optimize = optimize,
    });
    cb.addImport("bt", lib.bt.mod);
    cb.linkFramework("CoreBluetooth", .{});
    cb.linkFramework("Foundation", .{});
    cb.linkSystemLibrary("objc", .{});
    pkg.core_bluetooth.mod = cb;
}

fn runTests(b: *std.Build, lib: *const Lib, pkg: *const Pkg) void {
    const tests = Tests{};
    const test_step = b.step("test", "Run all tests");
    inline for (@typeInfo(Tests).@"struct".fields) |f| {
        const entry = @field(tests, f.name);
        if (entry.os.len == 0 or for (entry.os) |os| {
            if (os == host_os) break true;
        } else false) {
            switch (entry.from) {
                .lib => {
                    const t = b.addTest(.{ .root_module = @field(lib, f.name).mod });
                    test_step.dependOn(&b.addRunArtifact(t).step);
                },
                .pkg => {
                    if (@field(pkg, f.name).mod) |m| {
                        const t = b.addTest(.{ .root_module = m });
                        test_step.dependOn(&b.addRunArtifact(t).step);
                    }
                },
            }
        }
    }
}
