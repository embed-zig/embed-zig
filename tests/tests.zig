const builtin = @import("builtin");
const std = @import("std");
const target = if (builtin.is_test) @import("test_target") else struct {
    pub const os_tag = builtin.target.os.tag;
};

pub const Label = enum {
    integration,
    unit,
};

pub const modules = modulesFor(target.os_tag == .linux, target.os_tag == .macos);

pub fn modulesFor(comptime is_linux: bool, comptime is_macos: bool) @TypeOf(glib_unit_base_modules ++ includeIf(!is_linux, glib_unit_non_linux_modules) ++ includeIf(is_macos, glib_unit_macos_modules) ++ glib_integration_base_modules ++ includeIf(!is_linux, glib_integration_non_linux_modules) ++ includeIf(is_macos, glib_integration_macos_modules) ++ gstd_unit_base_modules ++ includeIf(!is_linux, gstd_unit_non_linux_modules) ++ includeIf(is_macos, gstd_unit_macos_modules) ++ desktop_unit_base_modules ++ esp_unit_base_modules ++ apps_unit_base_modules ++ apps_zux_base_modules ++ openapi_codegen_unit_base_modules ++ openapi_codegen_integration_base_modules ++ embed_unit_base_modules ++ includeIf(!is_linux, embed_unit_non_linux_modules) ++ includeIf(is_macos, embed_unit_macos_modules) ++ embed_integration_base_modules ++ includeIf(!is_linux, embed_integration_non_linux_modules) ++ includeIf(is_macos, embed_integration_macos_modules) ++ thirdparty_unit_base_modules ++ includeIf(!is_linux, thirdparty_unit_non_linux_modules) ++ includeIf(is_macos, thirdparty_unit_macos_modules) ++ thirdparty_integration_base_modules ++ includeIf(!is_linux, thirdparty_integration_non_linux_modules) ++ includeIf(is_macos, thirdparty_integration_macos_modules)) {
    return glib_unit_base_modules ++ includeIf(!is_linux, glib_unit_non_linux_modules) ++ includeIf(is_macos, glib_unit_macos_modules) ++ glib_integration_base_modules ++ includeIf(!is_linux, glib_integration_non_linux_modules) ++ includeIf(is_macos, glib_integration_macos_modules) ++ gstd_unit_base_modules ++ includeIf(!is_linux, gstd_unit_non_linux_modules) ++ includeIf(is_macos, gstd_unit_macos_modules) ++ desktop_unit_base_modules ++ esp_unit_base_modules ++ apps_unit_base_modules ++ apps_zux_base_modules ++ openapi_codegen_unit_base_modules ++ openapi_codegen_integration_base_modules ++ embed_unit_base_modules ++ includeIf(!is_linux, embed_unit_non_linux_modules) ++ includeIf(is_macos, embed_unit_macos_modules) ++ embed_integration_base_modules ++ includeIf(!is_linux, embed_integration_non_linux_modules) ++ includeIf(is_macos, embed_integration_macos_modules) ++ thirdparty_unit_base_modules ++ includeIf(!is_linux, thirdparty_unit_non_linux_modules) ++ includeIf(is_macos, thirdparty_unit_macos_modules) ++ thirdparty_integration_base_modules ++ includeIf(!is_linux, thirdparty_integration_non_linux_modules) ++ includeIf(is_macos, thirdparty_integration_macos_modules);
}

const glib_unit_base_modules = .{
    @import("glib_unit/context_gstd.zig"),
    @import("glib_unit/crypto_gstd.zig"),
    @import("glib_unit/io_gstd.zig"),
    @import("glib_unit/mime_gstd.zig"),
    @import("glib_unit/net_gstd.zig"),
    @import("glib_unit/stdz_gstd.zig"),
    @import("glib_unit/sync_gstd.zig"),
    @import("glib_unit/testing_gstd.zig"),
    @import("glib_unit/time_gstd.zig"),
};

const glib_unit_non_linux_modules = .{
    @import("glib_unit/context_std.zig"),
    @import("glib_unit/io_std.zig"),
    @import("glib_unit/mime_std.zig"),
    @import("glib_unit/net_std.zig"),
    @import("glib_unit/stdz_std.zig"),
    @import("glib_unit/sync_std.zig"),
    @import("glib_unit/testing_std.zig"),
    @import("glib_unit/time_std.zig"),
};

const glib_unit_macos_modules = .{};

const glib_integration_base_modules = .{
    @import("glib_integration/net_gstd.zig"),
    @import("glib_integration/sync_gstd.zig"),
};

const glib_integration_non_linux_modules = .{
    @import("glib_integration/net_std.zig"),
    @import("glib_integration/sync_std.zig"),
};

const glib_integration_macos_modules = .{};

const gstd_unit_base_modules = .{
    @import("gstd_unit/runtime_thread_gstd_small_explicit_stack.zig"),
    @import("gstd_unit/runtime_time_gstd.zig"),
};

const gstd_unit_non_linux_modules = .{};

const gstd_unit_macos_modules = .{};

const desktop_unit_base_modules = .{
    @import("desktop_unit/gstd.zig"),
    @import("desktop_unit/std.zig"),
};

const esp_unit_base_modules = .{
    @import("esp_unit/idf.zig"),
};

const apps_unit_base_modules = .{
    @import("apps_unit/glib_unit_test.zig"),
};

const apps_zux_base_modules = .{
    @import("apps_zux/button_ledstrip.zig"),
};

const openapi_codegen_unit_base_modules = .{
    @import("openapi_codegen/sse_test.zig"),
};

const openapi_codegen_integration_base_modules = .{
    @import("openapi_codegen/examples.zig"),
    @import("openapi_codegen/oapi-codegen.zig"),
    @import("openapi_codegen/stream_test.zig"),
};

const embed_unit_base_modules = .{
    @import("embed_unit/audio_gstd.zig"),
    @import("embed_unit/bt_gstd.zig"),
    @import("embed_unit/drivers_gstd.zig"),
    @import("embed_unit/ledstrip_gstd.zig"),
    @import("embed_unit/motion_gstd.zig"),
    @import("embed_unit/zux_gstd.zig"),
};

const embed_unit_non_linux_modules = .{
    @import("embed_unit/audio_std.zig"),
    @import("embed_unit/bt_std.zig"),
    @import("embed_unit/drivers_std.zig"),
    @import("embed_unit/ledstrip_std.zig"),
    @import("embed_unit/motion_std.zig"),
    @import("embed_unit/zux_std.zig"),
};

const embed_unit_macos_modules = .{};

const embed_integration_base_modules = .{
    @import("embed_integration/audio_gstd.zig"),
    @import("embed_integration/bt_gstd.zig"),
    @import("embed_integration/zux_gstd.zig"),
};

const embed_integration_non_linux_modules = .{
    @import("embed_integration/audio_std.zig"),
    @import("embed_integration/bt_std.zig"),
    @import("embed_integration/zux_std.zig"),
};

const embed_integration_macos_modules = .{};

const thirdparty_unit_base_modules = .{
    @import("thirdparty_unit/lvgl.zig"),
    @import("thirdparty_unit/mbedtls.zig"),
    @import("thirdparty_unit/opus_embed_std.zig"),
    @import("thirdparty_unit/opus_std.zig"),
    @import("thirdparty_unit/portaudio_embed_std.zig"),
    @import("thirdparty_unit/portaudio_imports.zig"),
    @import("thirdparty_unit/portaudio_root_surface_exposes_foundational_types.zig"),
    @import("thirdparty_unit/portaudio_std.zig"),
    @import("thirdparty_unit/speexdsp_embed_std.zig"),
    @import("thirdparty_unit/speexdsp_imports.zig"),
    @import("thirdparty_unit/speexdsp_root_surface_exposes_phase1_wrappers.zig"),
    @import("thirdparty_unit/speexdsp_std.zig"),
    @import("thirdparty_unit/stb_truetype.zig"),
};

const thirdparty_unit_non_linux_modules = .{};

const thirdparty_unit_macos_modules = .{
    @import("thirdparty_unit/core_bluetooth_embed_std.zig"),
    @import("thirdparty_unit/core_bluetooth_std.zig"),
    @import("thirdparty_unit/core_wlan_embed_std.zig"),
    @import("thirdparty_unit/core_wlan_std.zig"),
};

const thirdparty_integration_base_modules = .{
    @import("thirdparty_integration/lvgl.zig"),
    @import("thirdparty_integration/opus_embed_std.zig"),
    @import("thirdparty_integration/opus_std.zig"),
    @import("thirdparty_integration/portaudio_embed_std.zig"),
    @import("thirdparty_integration/portaudio_std.zig"),
    @import("thirdparty_integration/speexdsp_embed_std.zig"),
    @import("thirdparty_integration/speexdsp_std.zig"),
    @import("thirdparty_integration/stb_truetype_embed.zig"),
    @import("thirdparty_integration/stb_truetype_std.zig"),
};

const thirdparty_integration_non_linux_modules = .{};

const thirdparty_integration_macos_modules = .{
    @import("thirdparty_integration/core_bluetooth_embed_std.zig"),
    @import("thirdparty_integration/core_bluetooth_std.zig"),
    @import("thirdparty_integration/core_wlan_embed_std.zig"),
    @import("thirdparty_integration/core_wlan_std.zig"),
};

fn includeIf(comptime condition: bool, comptime values: anytype) if (condition) @TypeOf(values) else @TypeOf(.{}) {
    return if (condition) values else .{};
}

comptime {
    for (modules) |module| {
        _ = module.meta;
    }
}
