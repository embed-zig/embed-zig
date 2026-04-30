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
    const dep = b.modules.get("dep") orelse @panic("desktop requires dep");
    const openapi = b.modules.get("openapi") orelse @panic("openapi module missing");
    const codegen = b.modules.get("codegen") orelse @panic("codegen module missing");
    const api_spec = b.modules.get("desktop_api_spec") orelse @panic("desktop_api_spec module missing");
    const ui_assets = b.modules.get("desktop_ui_assets") orelse @panic("desktop_ui_assets module missing");
    const mod = b.modules.get("desktop") orelse @panic("desktop module missing");
    mod.addImport("dep", dep);
    mod.addImport("openapi", openapi);
    mod.addImport("codegen", codegen);
    mod.addImport("desktop_api_spec", api_spec);
    mod.addImport("desktop_ui_assets", ui_assets);
}
