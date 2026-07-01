const std = @import("std");
const esp = @import("esp");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app", "App module exported by the apps package") orelse "zux_button-ledstrip";
    const mode = b.option([]const u8, "mode", "Launcher mode: app or test") orelse "app";
    const board_name = b.option([]const u8, "board", "ESP board: devkit, szp, wv-esp32s3-touch-amoled-1.8, or wv-esp32p4-wifi6-touch-lcd-4.3") orelse "devkit";
    const build_dir = b.option([]const u8, "build", "Generated ESP-IDF build directory") orelse ".build";
    const ble_speed_transport = b.option([]const u8, "ble_speed_transport", "BLE speed transport: raw-gatt or kcp-stream") orelse "raw-gatt";
    const board_root = boardRoot(board_name);
    const esp_build_dep = b.dependency("esp", .{});
    const build_config_module = createBoardBuildConfigModule(
        b,
        esp_build_dep,
        esp_build_dep.module("esp"),
        board_root,
    );
    const context = esp.idf.resolveBuildContext(b, .{
        .build_config = build_config_module,
        .esp_dep = esp_build_dep,
        .build_dir = build_dir,
    });

    const esp_dep = b.dependency("esp", .{
        .target = context.target,
        .optimize = optimize,
    });
    const runtime_build_config_module = createBoardBuildConfigModule(
        b,
        esp_dep,
        esp_dep.module("esp"),
        board_root,
    );
    const esp_grt_module = esp_dep.module("esp").import_table.get("esp_grt") orelse
        @panic("esp module is missing esp_grt import");
    esp_grt_module.addImport("build_config", runtime_build_config_module);
    const apps_dep = b.dependency("apps", .{
        .target = context.target,
        .optimize = optimize,
        .lvgl_c_sysroot = if (context.toolchain_sysroot) |sysroot| sysroot.root else "",
        .lvgl_c_short_enums = true,
        .ble_speed_transport = ble_speed_transport,
    });
    const glib_dep = b.dependency("glib", .{
        .target = context.target,
        .optimize = optimize,
    });
    const selected_app = apps_dep.module(app_name);

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "lvgl_osal", .module = apps_dep.module("lvgl_osal") },
            .{ .name = "selected_app", .module = selected_app },
        },
        .link_libc = true,
    });
    const launcher_config = b.addOptions();
    launcher_config.addOption([]const u8, "board", board_name);
    launcher_config.addOption([]const u8, "mode", mode);
    entry_module.addOptions("esp_launcher_config", launcher_config);

    const board_component = addBoardComponent(b, esp_build_dep, board_name, board_root);
    const json_compat = addJsonCompatComponent(b);
    const app = esp.idf.addApp(b, "launcher", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = if (needsJsonCompat(board_name)) &.{ board_component, json_compat } else &.{board_component},
    });

    const build_step = b.step("build", "Build the ESP launcher example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the ESP launcher example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the ESP launcher example");
    monitor_step.dependOn(app.monitor);
}

fn createBoardBuildConfigModule(
    b: *std.Build,
    esp_dep: *std.Build.Dependency,
    esp_module: *std.Build.Module,
    board_root: []const u8,
) *std.Build.Module {
    const esp32s3_boards_common = b.createModule(.{
        .root_source_file = esp_dep.path("lib/boards/common/esp32s3.zig"),
    });
    return b.createModule(.{
        .root_source_file = esp_dep.path(join(b, board_root, "build_config.zig")),
        .imports = &.{
            .{ .name = "esp", .module = esp_module },
            .{ .name = "esp32s3_boards_common", .module = esp32s3_boards_common },
        },
    });
}

fn addBoardComponent(b: *std.Build, esp_dep: *std.Build.Dependency, board_name: []const u8, board_root: []const u8) *esp.idf.Component {
    if (std.mem.eql(u8, board_name, "szp")) return addSzpBoardComponent(b, esp_dep, board_root);
    if (std.mem.eql(u8, board_name, "wv-esp32s3-touch-amoled-1.8")) return addWvBoardComponent(b, esp_dep, board_root);
    if (std.mem.eql(u8, board_name, "wv-esp32p4-wifi6-touch-lcd-4.3")) return addWvP4BoardComponent(b, esp_dep, board_root);
    return addDevkitBoardComponent(b, esp_dep, board_root);
}

fn addDevkitBoardComponent(b: *std.Build, esp_dep: *std.Build.Dependency, board_root: []const u8) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = "devkit_board" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = esp_dep.path(join(b, board_root, "idf_component.yml")),
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path(join(b, board_root, "bindings")),
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
    component.addRequire("console");
    component.addRequire("esp_driver_gpio");
    component.addRequire("led_strip");
    component.addRequire("log");
    return component;
}

fn addSzpBoardComponent(b: *std.Build, esp_dep: *std.Build.Dependency, board_root: []const u8) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = "szp_board" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = esp_dep.path(join(b, board_root, "idf_component.yml")),
    });
    component.addIncludePath(esp_dep.path(join(b, board_root, "include")));
    component.addCSourceFiles(.{
        .root = esp_dep.path(join(b, board_root, "bindings")),
        .files = &.{
            "szp_board.c",
            "szp_storage.c",
            "szp_audio.c",
            "szp_button.c",
            "szp_display.c",
        },
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/audio"),
        .files = &.{ "es8311_es7210_native.c", "esp_sr_native.c" },
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/bt"),
        .files = &.{"local_hci.c"},
    });
    component.addRequire("driver");
    component.addRequire("console");
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_driver_i2s");
    component.addRequire("esp_driver_ledc");
    component.addRequire("esp_driver_spi");
    component.addRequire("esp_lcd");
    component.addRequire("bt");
    component.addRequire("esp-sr");
    component.addRequire("esp_timer");
    component.addRequire("log");
    component.addRequire("nvs_flash");
    component.addRequire("spiffs");
    return component;
}

fn addWvBoardComponent(b: *std.Build, esp_dep: *std.Build.Dependency, board_root: []const u8) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = "wv_board" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = esp_dep.path(join(b, board_root, "idf_component.yml")),
    });
    component.addIncludePath(esp_dep.path(join(b, board_root, "include")));
    component.addCSourceFiles(.{
        .root = esp_dep.path(join(b, board_root, "bindings")),
        .files = &.{
            "audio.c",
            "display.c",
            "power_button.c",
            "storage.c",
        },
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/bt"),
        .files = &.{"local_hci.c"},
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/audio"),
        .files = &.{ "es8311_native.c", "esp_sr_native.c" },
    });
    component.addRequire("driver");
    component.addRequire("bt");
    component.addRequire("console");
    component.addRequire("esp-sr");
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_driver_i2s");
    component.addRequire("esp_driver_spi");
    component.addRequire("esp_lcd");
    component.addRequire("esp_lcd_sh8601");
    component.addRequire("esp_timer");
    component.addRequire("log");
    component.addRequire("nvs_flash");
    return component;
}

fn addWvP4BoardComponent(b: *std.Build, esp_dep: *std.Build.Dependency, board_root: []const u8) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = "wv_p4_board" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = esp_dep.path(join(b, board_root, "idf_component.yml")),
    });
    component.addIncludePath(esp_dep.path(join(b, board_root, "include")));
    component.addCSourceFiles(.{
        .root = esp_dep.path(join(b, board_root, "bindings")),
        .files = &.{
            "audio.c",
            "display.c",
            "power_button.c",
        },
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/audio"),
        .files = &.{"es8311_es7210_native.c"},
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/bt"),
        .files = &.{"remote_hci.c"},
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed"),
        .files = &.{"hosted_copro.c"},
    });
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_driver_i2s");
    component.addRequire("esp_driver_ledc");
    component.addRequire("esp_app_format");
    component.addRequire("esp_event");
    component.addRequire("esp_hw_support");
    component.addRequire("esp_lcd");
    component.addRequire("esp_lcd_st7701");
    component.addRequire("esp_partition");
    component.addRequire("bootloader_support");
    component.addRequire("bt");
    component.addRequire("esp_hosted");
    component.addRequire("esp_wifi_remote");
    component.addRequire("log");
    component.addRequire("nvs_flash");
    return component;
}

fn addJsonCompatComponent(b: *std.Build) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = "json" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = b.path("components/json_compat/idf_component.yml"),
    });
    component.addRequire("espressif__cjson");
    return component;
}

fn needsJsonCompat(board_name: []const u8) bool {
    return std.mem.eql(u8, board_name, "szp") or
        std.mem.eql(u8, board_name, "wv-esp32s3-touch-amoled-1.8") or
        std.mem.eql(u8, board_name, "wv-esp32p4-wifi6-touch-lcd-4.3");
}

fn boardRoot(board_name: []const u8) []const u8 {
    if (std.mem.eql(u8, board_name, "devkit")) return "lib/boards/devkit";
    if (std.mem.eql(u8, board_name, "szp")) return "lib/boards/szp";
    if (std.mem.eql(u8, board_name, "wv-esp32s3-touch-amoled-1.8")) return "lib/boards/wv-esp32s3-touch-amoled-1.8";
    if (std.mem.eql(u8, board_name, "wv-esp32p4-wifi6-touch-lcd-4.3")) return "lib/boards/wv-esp32p4-wifi6-touch-lcd-4.3";
    std.debug.panic("unknown board '{s}', expected devkit, szp, wv-esp32s3-touch-amoled-1.8, or wv-esp32p4-wifi6-touch-lcd-4.3", .{board_name});
}

fn join(b: *std.Build, a: []const u8, b_part: []const u8) []const u8 {
    return std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ a, b_part }) catch @panic("OOM");
}
