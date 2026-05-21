const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/desktop.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("desktop", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("embed module missing");
    const glib = b.modules.get("glib") orelse @panic("glib module missing");
    const gstd = b.modules.get("gstd") orelse @panic("gstd module missing");
    const openapi = b.modules.get("openapi") orelse @panic("openapi module missing");
    const codegen = b.modules.get("codegen") orelse @panic("codegen module missing");
    const api_spec = b.modules.get("desktop_api_spec") orelse @panic("desktop_api_spec module missing");
    const ui_assets = b.modules.get("desktop_ui_assets") orelse @panic("desktop_ui_assets module missing");
    const core_bluetooth = b.modules.get("core_bluetooth") orelse @panic("core_bluetooth module missing");
    const core_wlan = b.modules.get("core_wlan") orelse @panic("core_wlan module missing");
    const portaudio = b.modules.get("portaudio") orelse @panic("portaudio module missing");
    const speexdsp = b.modules.get("speexdsp") orelse @panic("speexdsp module missing");
    const mod = b.modules.get("desktop") orelse @panic("desktop module missing");
    mod.addImport("embed", embed);
    mod.addImport("glib", glib);
    mod.addImport("gstd", gstd);
    mod.addImport("openapi", openapi);
    mod.addImport("codegen", codegen);
    mod.addImport("desktop_api_spec", api_spec);
    mod.addImport("desktop_ui_assets", ui_assets);
    mod.addImport("core_bluetooth", core_bluetooth);
    mod.addImport("core_wlan", core_wlan);
    mod.addImport("portaudio", portaudio);
    mod.addImport("speexdsp", speexdsp);
}
