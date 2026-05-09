const std = @import("std");
const esp = @import("esp");
const boards = @import("esp_boards");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const board_name = b.option([]const u8, "board", "Board component under boards/") orelse "devkit";

    const esp_build_dep = b.dependency("esp", .{});
    const build_config_module = boards.createBuildConfigModule(
        b,
        board_name,
        esp_build_dep.module("esp"),
    );
    const app_options_module = createAppOptionsModule(b);
    const context = esp.idf.resolveBuildContext(b, .{
        .build_config = build_config_module,
        .esp_dep = esp_build_dep,
    });

    if (context.toolchain_sysroot) |sysroot| {
        b.sysroot = sysroot.root;
    }

    const esp_dep = b.dependency("esp", .{
        .target = context.target,
        .optimize = optimize,
    });
    const embed_dep = b.dependency("embed", .{
        .target = context.target,
        .optimize = optimize,
    });
    const board_module = boards.createBoardModule(b, board_name, context.target, optimize, .{
        .embed = embed_dep.module("embed"),
        .esp = esp_dep.module("esp"),
    });

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
            .{ .name = "embed", .module = embed_dep.module("embed") },
            .{ .name = "app_options", .module = app_options_module },
            .{ .name = "selected_board", .module = board_module },
        },
        .link_libc = true,
    });

    const board_component = boards.addComponent(b, board_name);
    const app = esp.idf.addApp(b, "wifi_led_threads", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{board_component},
    });

    const build_step = b.step("build", "Build the wifi_led_threads example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the wifi_led_threads example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the wifi_led_threads example");
    monitor_step.dependOn(app.monitor);
}

fn createAppOptionsModule(b: *std.Build) *std.Build.Module {
    const wifi_ssid = b.option([]const u8, "wifi_ssid", "WiFi SSID for wifi_led_threads") orelse "demo-ssid";
    const wifi_password = b.option([]const u8, "wifi_password", "WiFi password for wifi_led_threads") orelse "demo-password";

    const write_files = b.addWriteFiles();
    const source = write_files.add("wifi_led_threads_app_options.zig", b.fmt(
        \\pub const wifi_ssid: [*:0]const u8 = "{f}";
        \\pub const wifi_password: [*:0]const u8 = "{f}";
        \\
    , .{
        std.zig.fmtString(wifi_ssid),
        std.zig.fmtString(wifi_password),
    }));

    return b.createModule(.{
        .root_source_file = source,
    });
}
