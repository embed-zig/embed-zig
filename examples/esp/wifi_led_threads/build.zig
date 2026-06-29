const std = @import("std");
const esp = @import("esp");

const board_root = "lib/boards/devkit";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const esp_build_dep = b.dependency("esp", .{});
    const build_config_module = createBoardBuildConfigModule(
        b,
        esp_build_dep,
        esp_build_dep.module("esp"),
    );
    const app_options_module = createAppOptionsModule(b);
    const context = esp.idf.resolveBuildContext(b, .{
        .build_config = build_config_module,
        .esp_dep = esp_build_dep,
    });

    const esp_dep = b.dependency("esp", .{
        .target = context.target,
        .optimize = optimize,
    });
    const runtime_build_config_module = createBoardBuildConfigModule(
        b,
        esp_dep,
        esp_dep.module("esp"),
    );
    const esp_grt_module = esp_dep.module("esp").import_table.get("esp_grt") orelse
        @panic("esp module is missing esp_grt import");
    esp_grt_module.addImport("build_config", runtime_build_config_module);
    const embed_module = esp_dep.module("esp_embed");

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
            .{ .name = "embed", .module = embed_module },
            .{ .name = "app_options", .module = app_options_module },
        },
        .link_libc = true,
    });

    const board_component = addBoardComponent(b, esp_build_dep);
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

fn createBoardBuildConfigModule(
    b: *std.Build,
    esp_dep: *std.Build.Dependency,
    esp_module: *std.Build.Module,
) *std.Build.Module {
    const esp32s3_boards_common = b.createModule(.{
        .root_source_file = esp_dep.path("lib/boards/common/esp32s3.zig"),
    });
    return b.createModule(.{
        .root_source_file = esp_dep.path(board_root ++ "/build_config.zig"),
        .imports = &.{
            .{ .name = "esp", .module = esp_module },
            .{ .name = "esp32s3_boards_common", .module = esp32s3_boards_common },
        },
    });
}

fn addBoardComponent(b: *std.Build, esp_dep: *std.Build.Dependency) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = "devkit_board" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = esp_dep.path(board_root ++ "/idf_component.yml"),
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path(board_root ++ "/bindings"),
        .files = &.{
            "power_button.c",
            "led_strip.c",
        },
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/bt"),
        .files = &.{"local_hci.c"},
    });
    component.addRequire("driver");
    component.addRequire("bt");
    component.addRequire("esp_driver_gpio");
    component.addRequire("led_strip");
    component.addRequire("log");
    return component;
}
