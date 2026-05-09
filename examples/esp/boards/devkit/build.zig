const std = @import("std");
const esp = @import("esp");

pub const name = "devkit";
pub const component_root = "../boards/devkit";

pub fn createBoardModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: struct {
        embed: *std.Build.Module,
        esp: *std.Build.Module,
    },
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(component_root ++ "/Board.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "embed", .module = deps.embed },
            .{ .name = "esp", .module = deps.esp },
        },
        .link_libc = true,
    });
}

pub fn createBuildConfigModule(
    b: *std.Build,
    esp_module: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(component_root ++ "/build_config.zig"),
        .imports = &.{
            .{ .name = "esp", .module = esp_module },
        },
    });
}

pub fn addComponent(b: *std.Build) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = "devkit_board" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = b.path(component_root ++ "/idf_component.yml"),
    });
    component.addCSourceFiles(.{
        .root = b.path(component_root ++ "/bindings"),
        .files = &.{
            "power_button.c",
            "led_strip.c",
        },
    });
    component.addRequire("driver");
    component.addRequire("esp_driver_gpio");
    component.addRequire("led_strip");
    component.addRequire("log");
    return component;
}
