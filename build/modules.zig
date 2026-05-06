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
    module2("thirdparty", "opus"),
    module2("thirdparty", "opus_osal"),
    module2("thirdparty", "portaudio"),
    module2("thirdparty", "speexdsp"),
    module2("thirdparty", "stb_truetype"),
};

pub const apps_modules = [_]ModuleSpec{
    module2("apps", "glib_unit-test"),
    module2("apps", "zux_button-ledstrip"),
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
