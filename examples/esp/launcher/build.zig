const std = @import("std");
const buildtools = @import("buildtools");
const esp = @import("esp");
const thirdparty_build = @import("thirdparty");

const lvgl_pkg = thirdparty_build.lvgl;

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app", "App module exported by the apps package") orelse "zux_button-ledstrip";
    const ble_speed_role = b.option([]const u8, "ble_speed_role", "BLE speed test role: client or server") orelse "client";
    const board_name = b.option([]const u8, "board", "ESP board: devkit, szp, or wv-esp32s3-touch-amoled-1.8") orelse "devkit";
    const build_dir = b.option([]const u8, "build", "Generated ESP-IDF build directory") orelse ".build";
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

    if (context.toolchain_sysroot) |sysroot| {
        b.sysroot = sysroot.root;
    }

    const esp_dep = b.dependency("esp", .{
        .target = context.target,
        .optimize = optimize,
    });
    const apps_dep = b.dependency("apps", .{
        .target = context.target,
        .optimize = optimize,
        .ble_speed_role = ble_speed_role,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
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
            .{ .name = "lvgl_osal", .module = thirdparty_dep.module("lvgl_osal") },
            .{ .name = "selected_app", .module = selected_app },
        },
        .link_libc = true,
    });
    const launcher_config = b.addOptions();
    launcher_config.addOption([]const u8, "board", board_name);
    entry_module.addOptions("esp_launcher_config", launcher_config);

    const board_component = addBoardComponent(b, esp_build_dep, board_name, board_root);
    const lvgl_component = addLvglComponent(b);
    const json_compat = addJsonCompatComponent(b);
    const app = esp.idf.addApp(b, "launcher", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = if (std.mem.eql(u8, board_name, "szp")) &.{ board_component, lvgl_component, json_compat } else &.{ board_component, lvgl_component },
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
    return b.createModule(.{
        .root_source_file = esp_dep.path(join(b, board_root, "build_config.zig")),
        .imports = &.{
            .{ .name = "esp", .module = esp_module },
        },
    });
}

fn addBoardComponent(b: *std.Build, esp_dep: *std.Build.Dependency, board_name: []const u8, board_root: []const u8) *esp.idf.Component {
    if (std.mem.eql(u8, board_name, "szp")) return addSzpBoardComponent(b, esp_dep, board_root);
    if (std.mem.eql(u8, board_name, "wv-esp32s3-touch-amoled-1.8")) return addWvBoardComponent(b, esp_dep, board_root);
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
            "wifi_sta.c",
        },
    });
    component.addRequire("driver");
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_event");
    component.addRequire("esp_netif");
    component.addRequire("esp_wifi");
    component.addRequire("led_strip");
    component.addRequire("log");
    component.addRequire("nvs_flash");
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
            "wifi_sta.c",
        },
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/bt"),
        .files = &.{"vhci.c"},
    });
    component.addRequire("driver");
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_driver_i2s");
    component.addRequire("esp_driver_ledc");
    component.addRequire("esp_driver_spi");
    component.addRequire("esp_event");
    component.addRequire("esp_lcd");
    component.addRequire("bt");
    component.addRequire("esp_netif");
    component.addRequire("esp_timer");
    component.addRequire("esp_wifi");
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
        .root = esp_dep.path("lib/boards/devkit/bindings"),
        .files = &.{
            "wifi_sta.c",
        },
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path("lib/embed/bt"),
        .files = &.{"vhci.c"},
    });
    component.addRequire("driver");
    component.addRequire("bt");
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_driver_i2s");
    component.addRequire("esp_driver_spi");
    component.addRequire("esp_event");
    component.addRequire("esp_lcd");
    component.addRequire("esp_lcd_sh8601");
    component.addRequire("esp_netif");
    component.addRequire("esp_timer");
    component.addRequire("esp_wifi");
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

fn addLvglComponent(b: *std.Build) *esp.idf.Component {
    const lvgl_archive = buildtools.addFetchArchive(b, .{
        .url = lvgl_pkg.upstream_tarball_url,
        .version_key = lvgl_pkg.upstream_version_key,
        .cache_namespace = "lvgl-upstream",
        .step_name = "launcher.lvgl.fetch-archive.ensure",
    });
    const component = esp.idf.Component.create(b, .{ .name = "lvgl" });
    component.addFile(.{ .relative_path = "lvgl.h", .file = lvgl_archive.path("lvgl.h") });
    component.addFile(.{ .relative_path = "lvgl_private.h", .file = lvgl_archive.path("lvgl_private.h") });
    component.addFile(.{ .relative_path = "src/lvgl.h", .file = lvgl_archive.path("lvgl.h") });
    component.addFile(.{ .relative_path = "src/lvgl_private.h", .file = lvgl_archive.path("lvgl_private.h") });
    component.addIncludePath(lvgl_archive.includePath("."));
    component.addIncludePath(b.path("components/lvgl_local/include"));
    component.addIncludePath(b.path("../../../thirdparty/pkg/lvgl/include"));
    const lvgl_sources = filterLvglSources(b, lvgl_pkg.c_sources);
    for (lvgl_sources) |source_file| {
        if (std.fs.path.dirname(source_file)) |source_dir| {
            component.addIncludePath(lvgl_archive.includePath(source_dir));
        }
    }
    component.addCSourceFiles(.{
        .root = lvgl_archive.root(),
        .files = lvgl_sources,
        .flags = &.{"-DLV_CONF_INCLUDE_SIMPLE=1"},
    });
    component.addCSourceFiles(.{
        .root = b.path("../../../thirdparty/pkg/lvgl/src"),
        .files = &.{"binding.c"},
        .flags = &.{"-DLV_CONF_INCLUDE_SIMPLE=1"},
    });
    return component;
}

fn filterLvglSources(b: *std.Build, sources: []const []const u8) []const []const u8 {
    var filtered = std.ArrayList([]const u8).empty;
    for (sources) |source| {
        if (!useLvglSource(source)) continue;
        filtered.append(b.allocator, source) catch @panic("OOM");
    }
    return filtered.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn useLvglSource(source: []const u8) bool {
    if (std.mem.startsWith(u8, source, "src/core/")) return true;
    if (std.mem.startsWith(u8, source, "src/display/")) return true;
    if (std.mem.startsWith(u8, source, "src/draw/convert/lv_draw_buf_convert")) return true;
    if (std.mem.startsWith(u8, source, "src/draw/lv_draw")) return true;
    if (std.mem.eql(u8, source, "src/draw/lv_image_decoder.c")) return true;
    if (std.mem.startsWith(u8, source, "src/draw/sw/")) return true;
    if (std.mem.eql(u8, source, "src/font/lv_font.c")) return true;
    if (std.mem.eql(u8, source, "src/font/fmt_txt/lv_font_fmt_txt.c")) return true;
    if (std.mem.eql(u8, source, "src/font/lv_font_montserrat_14.c")) return true;
    if (std.mem.startsWith(u8, source, "src/indev/")) return true;
    if (std.mem.eql(u8, source, "src/layouts/lv_layout.c")) return true;
    if (std.mem.eql(u8, source, "src/libs/bin_decoder/lv_bin_decoder.c")) return true;
    if (std.mem.startsWith(u8, source, "src/misc/")) return true;
    if (std.mem.eql(u8, source, "src/osal/lv_os.c")) return true;
    if (std.mem.eql(u8, source, "src/osal/lv_os_none.c")) return true;
    if (std.mem.startsWith(u8, source, "src/stdlib/")) return true;
    if (std.mem.startsWith(u8, source, "src/themes/")) return true;
    if (std.mem.startsWith(u8, source, "src/tick/")) return true;
    if (std.mem.eql(u8, source, "src/lv_init.c")) return true;
    if (std.mem.eql(u8, source, "src/widgets/bar/lv_bar.c")) return true;
    if (std.mem.eql(u8, source, "src/widgets/button/lv_button.c")) return true;
    if (std.mem.eql(u8, source, "src/widgets/label/lv_label.c")) return true;
    return false;
}

fn boardRoot(board_name: []const u8) []const u8 {
    if (std.mem.eql(u8, board_name, "devkit")) return "lib/boards/devkit";
    if (std.mem.eql(u8, board_name, "szp")) return "lib/boards/szp";
    if (std.mem.eql(u8, board_name, "wv-esp32s3-touch-amoled-1.8")) return "lib/boards/wv-esp32s3-touch-amoled-1.8";
    std.debug.panic("unknown board '{s}', expected devkit, szp, or wv-esp32s3-touch-amoled-1.8", .{board_name});
}

fn join(b: *std.Build, a: []const u8, b_part: []const u8) []const u8 {
    return std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ a, b_part }) catch @panic("OOM");
}
