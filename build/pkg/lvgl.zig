const std = @import("std");
const GitRepo = @import("../GitRepo.zig");

var library: ?*std.Build.Step.Compile = null;
var osal_library: ?*std.Build.Step.Compile = null;
var osal_module: ?*std.Build.Module = null;
var resolved_target: ?std.Build.ResolvedTarget = null;
var resolved_optimize: ?std.builtin.OptimizeMode = null;

const bundled_custom_include = "lv_os_custom.h";

const StdlibBackend = enum {
    LV_STDLIB_BUILTIN,
    LV_STDLIB_CLIB,
    LV_STDLIB_MICROPYTHON,
    LV_STDLIB_RTTHREAD,
    LV_STDLIB_CUSTOM,
};

const OsBackend = enum {
    LV_OS_NONE,
    LV_OS_PTHREAD,
    LV_OS_FREERTOS,
    LV_OS_CMSIS_RTOS2,
    LV_OS_RTTHREAD,
    LV_OS_WINDOWS,
    LV_OS_MQX,
    LV_OS_SDL2,
    LV_OS_CUSTOM,
};

const ConfigHeaderValues = struct {
    LV_COLOR_DEPTH: u8 = 16,
    LV_USE_STDLIB_MALLOC: StdlibBackend = .LV_STDLIB_BUILTIN,
    LV_USE_STDLIB_STRING: StdlibBackend = .LV_STDLIB_BUILTIN,
    LV_USE_STDLIB_SPRINTF: StdlibBackend = .LV_STDLIB_BUILTIN,
    LV_MEM_SIZE: u32 = 64 * 1024,
    LV_USE_OS: OsBackend = .LV_OS_CUSTOM,
    LV_OS_CUSTOM_INCLUDE: ?[]const u8 = null,
    LV_USE_FLOAT: u8 = 0,
    LV_USE_MATRIX: u8 = 0,
    LV_USE_OBSERVER: u8 = 1,
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    resolved_target = target;
    resolved_optimize = optimize;

    const repo = GitRepo.addGitRepo(b, .{
        .git_repo = "https://github.com/lvgl/lvgl.git",
        .commit = "85aa60d18b3d5e5588d7b247abf90198f07c8a63",
    });
    const config_header = createConfigHeader(b);
    const c_sources = collectCSources(b, repo);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lvgl",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    lib.root_module.addConfigHeader(config_header);
    lib.root_module.addIncludePath(repo.includePath("."));
    lib.root_module.addIncludePath(b.path("pkg/lvgl/include"));
    if (b.sysroot) |sysroot| {
        lib.root_module.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    lib.root_module.addCSourceFiles(.{
        .root = repo.root(),
        .files = c_sources,
    });
    lib.root_module.addCSourceFile(.{ .file = b.path("pkg/lvgl/src/binding.c") });
    repo.dependOn(&lib.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/lvgl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addConfigHeader(config_header);
    mod.addIncludePath(repo.includePath("."));
    mod.addIncludePath(b.path("pkg/lvgl/include"));
    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    b.modules.put("lvgl", mod) catch @panic("OOM");

    const osal_mod = b.createModule(.{
        .root_source_file = b.path("pkg/lvgl_osal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    osal_mod.addConfigHeader(config_header);
    osal_mod.addIncludePath(repo.includePath("."));
    osal_mod.addIncludePath(b.path("pkg/lvgl/include"));
    if (b.sysroot) |sysroot| {
        osal_mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    b.modules.put("lvgl_osal", osal_mod) catch @panic("OOM");

    b.installArtifact(lib);
    library = lib;
    osal_module = osal_mod;
}

pub fn link(b: *std.Build) void {
    const lib = library orelse @panic("lvgl library missing");
    const mod = b.modules.get("lvgl") orelse @panic("lvgl module missing");
    mod.linkLibrary(lib);
}

pub fn linkTest(_: *std.Build, compile: *std.Build.Step.Compile) void {
    const osal = osal_library orelse createOsalLibrary(compile.step.owner);
    const embed = compile.step.owner.modules.get("embed") orelse @panic("lvgl tests require embed");
    const testing = compile.step.owner.modules.get("testing") orelse @panic("lvgl tests require testing");
    compile.root_module.addImport("embed", embed);
    compile.root_module.addImport("testing", testing);
    compile.linkLibrary(osal);
}

fn createOsalLibrary(b: *std.Build) *std.Build.Step.Compile {
    if (osal_library) |osal| return osal;

    const target = resolved_target orelse @panic("lvgl target missing");
    const optimize = resolved_optimize orelse @panic("lvgl optimize missing");
    const repo = GitRepo.addGitRepo(b, .{
        .git_repo = "https://github.com/lvgl/lvgl.git",
        .commit = "85aa60d18b3d5e5588d7b247abf90198f07c8a63",
    });
    const embed = b.modules.get("embed") orelse @panic("lvgl osal impl requires embed");
    const impl_mod = b.createModule(.{
        .root_source_file = b.path("lib/embed_std/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    impl_mod.addImport("embed", embed);
    const osal_mod = osal_module orelse @panic("lvgl_osal module missing");
    const write_files = b.addWriteFiles();
    const root_source = write_files.add("lvgl_osal_root.zig",
        \\const std = @import("std");
        \\const embed = @import("embed");
        \\const lvgl_osal = @import("lvgl_osal");
        \\const runtime = embed.make(@import("lvgl_osal_impl"));
        \\
        \\comptime {
        \\    _ = lvgl_osal.make(runtime, std.heap.page_allocator);
        \\}
        \\
    );

    const osal = b.addLibrary(.{
        .linkage = .static,
        .name = "lvgl_osal",
        .root_module = b.createModule(.{
            .root_source_file = root_source,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    osal.root_module.addImport("embed", embed);
    osal.root_module.addImport("lvgl_osal_impl", impl_mod);
    osal.root_module.addImport("lvgl_osal", osal_mod);
    repo.dependOn(&osal.step);

    osal_library = osal;
    return osal;
}

fn createConfigHeader(
    b: *std.Build,
) *std.Build.Step.ConfigHeader {
    return b.addConfigHeader(.{
        .style = .{ .autoconf_undef = b.path("pkg/lvgl/config.h.in") },
        .include_path = "lv_conf.h",
    }, ConfigHeaderValues{
        .LV_USE_OS = .LV_OS_CUSTOM,
        .LV_OS_CUSTOM_INCLUDE = bundled_custom_include,
    });
}

fn collectCSources(
    b: *std.Build,
    repo: GitRepo.GitRepo,
) []const []const u8 {
    const repo_root = repo.root().getPath(b);
    const resolved_root = if (std.fs.path.isAbsolute(repo_root))
        repo_root
    else
        b.pathFromRoot(repo_root);

    var root_dir = std.fs.openDirAbsolute(resolved_root, .{ .iterate = true }) catch @panic("lvgl repo missing");
    defer root_dir.close();

    var walker = root_dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    var sources = std.ArrayList([]const u8).initCapacity(b.allocator, 0) catch @panic("OOM");
    while (walker.next() catch @panic("lvgl source walk failed")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, "src/")) continue;
        if (!std.mem.endsWith(u8, entry.path, ".c")) continue;
        sources.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }

    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return sources.toOwnedSlice(b.allocator) catch @panic("OOM");
}
