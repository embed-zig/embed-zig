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
const zux_task_smoke = @import("zux/task-smoke/build.zig");
const zux_time_smoke = @import("zux/time-smoke/build.zig");

const AppRegistry = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    launcher: *std.Build.Module,
    glib_empty_zux_app: *std.Build.Module,
    modules: std.StringHashMap(*std.Build.Module),

    fn init(
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        launcher: *std.Build.Module,
        glib_empty_zux_app: *std.Build.Module,
    ) AppRegistry {
        return .{
            .b = b,
            .target = target,
            .optimize = optimize,
            .launcher = launcher,
            .glib_empty_zux_app = glib_empty_zux_app,
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
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    var registry = AppRegistry.init(b, target, optimize, launcher, glib_empty_zux_app);
    defer registry.deinit();

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
    zux_task_smoke.register(&registry);
    zux_time_smoke.register(&registry);
}
