const std = @import("std");
const esp = @import("esp");

const devkit = @import("devkit/build.zig");

pub fn createBuildConfigModule(
    b: *std.Build,
    name: []const u8,
    esp_module: *std.Build.Module,
) *std.Build.Module {
    if (std.mem.eql(u8, name, devkit.name)) {
        return devkit.createBuildConfigModule(b, esp_module);
    }
    std.debug.panic("unknown ESP launcher board: {s}", .{name});
}

pub fn createBoardModule(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: struct {
        embed: *std.Build.Module,
        esp: *std.Build.Module,
    },
) *std.Build.Module {
    if (std.mem.eql(u8, name, devkit.name)) {
        return devkit.createBoardModule(b, target, optimize, .{
            .embed = deps.embed,
            .esp = deps.esp,
        });
    }
    std.debug.panic("unknown ESP launcher board: {s}", .{name});
}

pub fn addComponent(b: *std.Build, name: []const u8) *esp.idf.Component {
    if (std.mem.eql(u8, name, devkit.name)) {
        return devkit.addComponent(b);
    }
    std.debug.panic("unknown ESP launcher board: {s}", .{name});
}
