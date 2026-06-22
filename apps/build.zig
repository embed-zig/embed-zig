const std = @import("std");

const glib_integration_test_net = @import("glib/integration-test/net/build.zig");
const glib_integration_test_sync = @import("glib/integration-test/sync/build.zig");
const glib_unit_test_context = @import("glib/unit-test/context/build.zig");
const glib_unit_test_io = @import("glib/unit-test/io/build.zig");
const glib_unit_test_mime = @import("glib/unit-test/mime/build.zig");
const glib_unit_test_net = @import("glib/unit-test/net/build.zig");
const glib_unit_test_std = @import("glib/unit-test/std/build.zig");
const glib_unit_test_sync = @import("glib/unit-test/sync/build.zig");
const glib_unit_test_testing = @import("glib/unit-test/testing/build.zig");
const zux_archive_smoke = @import("zux/archive-smoke/build.zig");
const zux_button_ledstrip = @import("zux/button-ledstrip/build.zig");
const zux_compress_smoke = @import("zux/compress-smoke/build.zig");
const zux_fs_smoke = @import("zux/fs-smoke/build.zig");
const zux_preferences_smoke = @import("zux/preferences-smoke/build.zig");
const zux_sync_smoke = @import("zux/sync-smoke/build.zig");
const zux_system_smoke = @import("zux/system-smoke/build.zig");
const zux_task_smoke = @import("zux/task-smoke/build.zig");
const zux_time_smoke = @import("zux/time-smoke/build.zig");

const AppRegistry = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    launcher: *std.Build.Module,
    glib_empty_zux_app: *std.Build.Module,
    lvgl_c_sysroot: []const u8,
    lvgl_c_short_enums: bool,
    modules: std.StringHashMap(*std.Build.Module),

    fn init(
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        launcher: *std.Build.Module,
        glib_empty_zux_app: *std.Build.Module,
        lvgl_c_sysroot: []const u8,
        lvgl_c_short_enums: bool,
    ) AppRegistry {
        return .{
            .b = b,
            .target = target,
            .optimize = optimize,
            .launcher = launcher,
            .glib_empty_zux_app = glib_empty_zux_app,
            .lvgl_c_sysroot = lvgl_c_sysroot,
            .lvgl_c_short_enums = lvgl_c_short_enums,
            .modules = std.StringHashMap(*std.Build.Module).init(b.allocator),
        };
    }

    fn deinit(self: *AppRegistry) void {
        self.modules.deinit();
    }

    pub fn add(
        self: *AppRegistry,
        name: []const u8,
        module: *std.Build.Module,
    ) void {
        if (self.modules.contains(name)) {
            std.debug.panic("duplicate app module '{s}'", .{name});
        }
        self.modules.put(name, module) catch @panic("OOM");
    }

    pub fn thirdpartyModule(self: *AppRegistry, name: []const u8) *std.Build.Module {
        return self.b.dependency("thirdparty", .{
            .target = self.target,
            .optimize = self.optimize,
            .lvgl_c_sysroot = self.lvgl_c_sysroot,
            .lvgl_c_short_enums = self.lvgl_c_short_enums,
        }).module(name);
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lvgl_c_sysroot = b.option([]const u8, "lvgl_c_sysroot", "Optional C sysroot passed to the LVGL package") orelse "";
    const lvgl_c_short_enums = b.option(bool, "lvgl_c_short_enums", "Pass -fshort-enums to the LVGL C build") orelse false;

    const glib = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    }).module("glib");

    const launcher = b.addModule("launcher", .{
        .root_source_file = b.path("src/Launcher.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib },
        },
    });
    const glib_empty_zux_app = b.addModule("glib_empty_zux_app", .{
        .root_source_file = b.path("glib/src/EmptyZuxApp.zig"),
        .target = target,
        .optimize = optimize,
    });

    var registry = AppRegistry.init(b, target, optimize, launcher, glib_empty_zux_app, lvgl_c_sysroot, lvgl_c_short_enums);
    defer registry.deinit();
    b.modules.put("lvgl", registry.thirdpartyModule("lvgl")) catch @panic("OOM");
    b.modules.put("lvgl_osal", registry.thirdpartyModule("lvgl_osal")) catch @panic("OOM");

    glib_unit_test_std.register(&registry);
    glib_unit_test_mime.register(&registry);
    glib_unit_test_testing.register(&registry);
    glib_unit_test_io.register(&registry);
    glib_unit_test_context.register(&registry);
    glib_unit_test_sync.register(&registry);
    glib_unit_test_net.register(&registry);
    glib_integration_test_sync.register(&registry);
    glib_integration_test_net.register(&registry);
    zux_archive_smoke.register(&registry);
    zux_button_ledstrip.register(&registry);
    zux_compress_smoke.register(&registry);
    zux_fs_smoke.register(&registry);
    zux_preferences_smoke.register(&registry);
    zux_sync_smoke.register(&registry);
    zux_system_smoke.register(&registry);
    zux_task_smoke.register(&registry);
    zux_time_smoke.register(&registry);
}
