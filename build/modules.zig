pub const ModuleSpec = struct {
    import_name: []const u8,
    export_name: []const u8,
    dependency_module_name: []const u8,
};

pub const base_test_modules = [_]ModuleSpec{
    module("glib"),
    module("gstd"),
    module("embed"),
    module("openapi"),
    module("codegen"),
    module("desktop"),
    module("esp"),
};

pub const thirdparty_modules = [_]ModuleSpec{
    module2("thirdparty", "core_bluetooth"),
    module2("thirdparty", "core_wlan"),
    module2("thirdparty", "lvgl"),
    module2("thirdparty", "lvgl_osal"),
    module2("thirdparty", "mbedtls"),
    module2("thirdparty", "mbedtls_osal"),
    module2("thirdparty", "opus"),
    module2("thirdparty", "opus_osal"),
    module2("thirdparty", "portaudio"),
    module2("thirdparty", "speexdsp"),
    module2("thirdparty", "stb_truetype"),
};

pub const apps_modules = [_]ModuleSpec{
    module2("apps", "glib_unit-test-std"),
    module2("apps", "glib_unit-test-mime"),
    module2("apps", "glib_unit-test-testing"),
    module2("apps", "glib_unit-test-io"),
    module2("apps", "glib_unit-test-context"),
    module2("apps", "glib_unit-test-sync"),
    module2("apps", "glib_unit-test-net"),
    module2("apps", "glib_integration-test-sync"),
    module2("apps", "glib_integration-test-net"),
    module2("apps", "zux_button-ledstrip"),
    module2("apps", "zux_archive-smoke"),
    module2("apps", "zux_compress-smoke"),
    module2("apps", "zux_fs-smoke"),
    module2("apps", "zux_preferences-smoke"),
    module2("apps", "zux_sync-smoke"),
    module2("apps", "zux_system-smoke"),
    module2("apps", "zux_task-smoke"),
    module2("apps", "zux_time-smoke"),
};

fn module(name: []const u8) ModuleSpec {
    return .{
        .import_name = name,
        .export_name = name,
        .dependency_module_name = name,
    };
}

fn module2(p0: []const u8, name: []const u8) ModuleSpec {
    return .{
        .import_name = name,
        .export_name = p0 ++ "/" ++ name,
        .dependency_module_name = name,
    };
}
