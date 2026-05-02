const std = @import("std");

const unit_test_std = @import("app/00-unit-test/00-std/build.zig");
const zux_button_ledstrip = @import("app/02-zux/00-button-ledstrip/build.zig");

const AppRegistry = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: std.StringHashMap(*std.Build.Module),

    fn init(
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) AppRegistry {
        return .{
            .b = b,
            .target = target,
            .optimize = optimize,
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
            std.debug.panic("duplicate example app module '{s}'", .{name});
        }
        self.modules.put(name, module) catch @panic("OOM");
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var registry = AppRegistry.init(b, target, optimize);
    defer registry.deinit();

    unit_test_std.register(&registry);
    zux_button_ledstrip.register(&registry);
}
