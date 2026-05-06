const std = @import("std");

const glib_unit_test = @import("glib/unit-test/build.zig");
const zux_button_ledstrip = @import("zux/button-ledstrip/build.zig");

const AppRegistry = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    launcher: *std.Build.Module,
    modules: std.StringHashMap(*std.Build.Module),

    fn init(
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        launcher: *std.Build.Module,
    ) AppRegistry {
        return .{
            .b = b,
            .target = target,
            .optimize = optimize,
            .launcher = launcher,
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

    var registry = AppRegistry.init(b, target, optimize, launcher);
    defer registry.deinit();

    glib_unit_test.register(&registry);
    zux_button_ledstrip.register(&registry);
}
