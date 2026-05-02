const std = @import("std");
const builtin = @import("builtin");

const lib_desktop = @import("build/lib/desktop.zig");

const Libraries = struct {
    pub const desktop = lib_desktop;
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    createDependencyModules(b, target, optimize);
    createApiSpecModule(b, target, optimize);
    const ui_bundle = createUiBundle(b, target, optimize);

    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        @field(Libraries, decl.name).create(b, target, optimize);
    }

    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        @field(Libraries, decl.name).link(b);
    }

    const ui_step = b.step("ui-build", "Bundle the desktop UI into zig-out/ui");
    ui_step.dependOn(&ui_bundle.install.step);
    b.getInstallStep().dependOn(&ui_bundle.install.step);
}

fn createDependencyModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const openapi_codegen_dep = b.dependency("openapi_codegen", .{
        .target = target,
        .optimize = optimize,
    });

    b.modules.put("embed", embed_dep.module("embed")) catch @panic("OOM");
    b.modules.put("glib", glib_dep.module("glib")) catch @panic("OOM");
    b.modules.put("gstd", gstd_dep.module("gstd")) catch @panic("OOM");
    b.modules.put("openapi", openapi_codegen_dep.module("openapi")) catch @panic("OOM");
    b.modules.put("codegen", openapi_codegen_dep.module("codegen")) catch @panic("OOM");
}

const UiBundle = struct {
    install: *std.Build.Step.InstallDir,
};

fn createUiBundle(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) UiBundle {
    const script =
        \\set -eu
        \\out="$1"
        \\bun install --frozen-lockfile
        \\bun run generate:api
        \\bun build ./src/main.ts ./src/desktop-core.ts --outdir "$out" --target browser --entry-naming='[name].[ext]' --chunk-naming='[name].[ext]' --asset-naming='[name].[ext]'
        \\cp ./src/index.html "$out/index.html"
        \\cp ./src/styles.css "$out/styles.css"
        \\cat > "$out/assets.zig" <<'EOF'
        \\pub const index_html = @embedFile("index.html");
        \\pub const main_js = @embedFile("main.js");
        \\pub const desktop_core_js = @embedFile("desktop-core.js");
        \\pub const styles_css = @embedFile("styles.css");
        \\EOF
    ;

    const run = b.addSystemCommand(&.{ "/bin/sh", "-c", script, "desktop-ui-bundle" });
    run.setCwd(b.path("ui"));
    useNativeToolPath(b, run);
    const output_dir = run.addOutputDirectoryArg("desktop-ui");

    const assets_module = b.createModule(.{
        .root_source_file = output_dir.path(b, "assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("desktop_ui_assets", assets_module) catch @panic("OOM");

    const install = b.addInstallDirectory(.{
        .source_dir = output_dir,
        .install_dir = .prefix,
        .install_subdir = "ui",
    });

    return .{
        .install = install,
    };
}

fn useNativeToolPath(b: *std.Build, run: *std.Build.Step.Run) void {
    switch (builtin.target.os.tag) {
        .linux => {
            const system_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
            const path = if (b.graph.env_map.get("HOME")) |home|
                b.fmt("{s}/.bun/bin:{s}", .{ home, system_path })
            else
                system_path;
            run.setEnvironmentVariable("PATH", path);
        },
        else => {},
    }
}

fn createApiSpecModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const script =
        \\set -eu
        \\out="$1"
        \\cp ./api.json "$out/api.json"
        \\cat > "$out/spec.zig" <<'EOF'
        \\pub const raw_api = @embedFile("api.json");
        \\EOF
    ;

    const run = b.addSystemCommand(&.{ "/bin/sh", "-c", script, "desktop-api-spec" });
    run.setCwd(b.path("."));
    const output_dir = run.addOutputDirectoryArg("desktop-api-spec");

    const spec_module = b.createModule(.{
        .root_source_file = output_dir.path(b, "spec.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("desktop_api_spec", spec_module) catch @panic("OOM");
}
