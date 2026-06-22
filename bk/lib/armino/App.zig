const std = @import("std");
const BuildContext = @import("BuildContext.zig");
const Component = @import("Component.zig");
const Config = @import("Config.zig");
const PartitionTable = @import("PartitionTable.zig");
const RamRegions = @import("RamRegions.zig");

const Self = @This();

package: *std.Build.Step,
flash: *std.Build.Step,
monitor: *std.Build.Step,
firmware_bin: []const u8,

pub const SideOptions = struct {
    root_source_file: std.Build.LazyPath,
    c_source_file: std.Build.LazyPath,
    config_file: ?std.Build.LazyPath = null,
    config: ?[]const u8 = null,
};

pub const PartitionOptions = struct {
    auto: ?std.Build.LazyPath = null,
    ram_regions: ?std.Build.LazyPath = null,
};

pub fn addDualCoreApp(b: *std.Build, app_name: []const u8, opts: anytype) Self {
    const context: BuildContext = opts.context;
    const prepare_python = addPreparePythonStep(b, context);
    const prepare_toolchain = addPrepareToolchainStep(b, context);
    const project = createProjectFiles(b, app_name, context, opts, prepare_toolchain);
    const firmware_bin = context.firmwareBin(b, app_name);

    const armino_build = b.addSystemCommand(&.{
        "make",
        context.make_target,
        b.fmt("SDK_DIR={s}", .{context.armino_path}),
        b.fmt("BUILD_DIR={s}", .{context.armino_build_dir}),
    });
    armino_build.setCwd(project);
    armino_build.setEnvironmentVariable("COMPILER_TOOLCHAIN_PATH", context.toolchain_path);
    armino_build.setEnvironmentVariable("ARMINO_PYTHON_ENV_PATH", context.python_venv_dir);
    armino_build.setEnvironmentVariable("PATH", prependPath(b, context.python_path_dir));
    armino_build.step.dependOn(prepare_python);
    armino_build.step.dependOn(prepare_toolchain);

    const stage_firmware = addStageFirmwareStep(b, context, project, firmware_bin, &armino_build.step);

    const package_step = b.step("package", b.fmt("Build BK app {s}", .{app_name}));
    package_step.dependOn(stage_firmware);

    const flash_step = b.step("flash", b.fmt("Flash BK app {s}", .{app_name}));
    flash_step.dependOn(addFlashStep(b, context, firmware_bin, stage_firmware, opts));

    const monitor_step = b.step("monitor", b.fmt("Monitor BK app {s}", .{app_name}));
    monitor_step.dependOn(addMonitorStep(b, context, project, prepare_python));

    return .{
        .package = package_step,
        .flash = flash_step,
        .monitor = monitor_step,
        .firmware_bin = firmware_bin,
    };
}

fn addPreparePythonStep(b: *std.Build, context: BuildContext) *std.Build.Step {
    const sdk_root_requirements = b.pathJoin(&.{ context.armino_path, "requirements.txt" });
    const sdk_ap_requirements = b.pathJoin(&.{ context.armino_path, "ap", "requirements.txt" });
    const sdk_cp_requirements = b.pathJoin(&.{ context.armino_path, "cp", "requirements.txt" });
    const script = b.fmt(
        \\set -eu
        \\venv={s}
        \\python="$venv/bin/python3"
        \\if [ ! -x "$python" ]; then
        \\  mkdir -p "$(dirname "$venv")"
        \\  python3 -m venv "$venv"
        \\fi
        \\ready="$venv/.bk-armino-ready"
        \\if ! "$python" -c 'import click, click_option_group, Crypto, cryptography, jinja2, yaml, cbor2, intelhex, serial' >/dev/null 2>&1 || ! grep -qxF {s} "$ready" 2>/dev/null; then
        \\  "$python" -m pip install --upgrade pip
        \\  "$python" -m pip install pycryptodome click future click_option_group 'cryptography>=40' jinja2 PyYAML cbor2 intelhex pyserial
        \\  for req in {s} {s} {s}; do
        \\    if [ -s "$req" ]; then
        \\      "$python" -m pip install -r "$req"
        \\    fi
        \\  done
        \\  printf '%s\n' {s} > "$ready"
        \\fi
        \\
    , .{
        shQuote(b, context.python_venv_dir),
        shQuote(b, context.armino_path),
        shQuote(b, sdk_root_requirements),
        shQuote(b, sdk_ap_requirements),
        shQuote(b, sdk_cp_requirements),
        shQuote(b, context.armino_path),
    });
    const run = b.addSystemCommand(&.{ "sh", "-c", script });
    return &run.step;
}

fn addPrepareToolchainStep(b: *std.Build, context: BuildContext) *std.Build.Step {
    const archive_dir = std.fs.path.dirname(context.toolchain_archive_path) orelse ".";
    const script = b.fmt(
        \\set -eu
        \\toolchain_dir={s}
        \\archive={s}
        \\archive_dir={s}
        \\url={s}
        \\gcc="$toolchain_dir/bin/arm-none-eabi-gcc"
        \\if [ ! -x "$gcc" ]; then
        \\  mkdir -p "$archive_dir" "$(dirname "$toolchain_dir")"
        \\  if [ ! -s "$archive" ]; then
        \\    tmp="$archive.tmp.$$"
        \\    rm -f "$tmp"
        \\    if command -v curl >/dev/null 2>&1; then
        \\      curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
        \\    elif command -v wget >/dev/null 2>&1; then
        \\      wget -O "$tmp" "$url"
        \\    else
        \\      echo "curl or wget is required to download the BK Arm GCC toolchain" >&2
        \\      exit 1
        \\    fi
        \\    mv "$tmp" "$archive"
        \\  fi
        \\  rm -rf "$toolchain_dir"
        \\  tar -xjf "$archive" -C "$(dirname "$toolchain_dir")"
        \\fi
        \\if [ ! -x "$gcc" ]; then
        \\  echo "BK Arm GCC toolchain was not installed at $gcc" >&2
        \\  exit 1
        \\fi
        \\
    , .{
        shQuote(b, context.toolchain_dir),
        shQuote(b, context.toolchain_archive_path),
        shQuote(b, archive_dir),
        shQuote(b, context.toolchain_url),
    });
    const run = b.addSystemCommand(&.{ "sh", "-c", script });
    return &run.step;
}

fn addPrepareMklittlefsStep(b: *std.Build, context: BuildContext) *std.Build.Step {
    const archive_dir = std.fs.path.dirname(context.mklittlefs_archive_path) orelse ".";
    const tools_dir = std.fs.path.dirname(std.fs.path.dirname(context.mklittlefs_path).?) orelse ".";
    const script = b.fmt(
        \\set -eu
        \\tool={s}
        \\archive={s}
        \\archive_dir={s}
        \\tools_dir={s}
        \\url={s}
        \\if [ ! -x "$tool" ]; then
        \\  mkdir -p "$archive_dir" "$tools_dir"
        \\  if [ ! -s "$archive" ]; then
        \\    tmp="$archive.tmp.$$"
        \\    rm -f "$tmp"
        \\    if command -v curl >/dev/null 2>&1; then
        \\      curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
        \\    elif command -v wget >/dev/null 2>&1; then
        \\      wget -O "$tmp" "$url"
        \\    else
        \\      echo "curl or wget is required to download mklittlefs" >&2
        \\      exit 1
        \\    fi
        \\    mv "$tmp" "$archive"
        \\  fi
        \\  rm -rf "$(dirname "$tool")"
        \\  tar -xzf "$archive" -C "$tools_dir"
        \\fi
        \\if [ ! -x "$tool" ]; then
        \\  echo "mklittlefs was not installed at $tool" >&2
        \\  exit 1
        \\fi
        \\
    , .{
        shQuote(b, context.mklittlefs_path),
        shQuote(b, context.mklittlefs_archive_path),
        shQuote(b, archive_dir),
        shQuote(b, tools_dir),
        shQuote(b, context.mklittlefs_url),
    });
    const run = b.addSystemCommand(&.{ "sh", "-c", script });
    return &run.step;
}

fn createProjectFiles(
    b: *std.Build,
    app_name: []const u8,
    context: BuildContext,
    opts: anytype,
    prepare_toolchain: *std.Build.Step,
) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.add("Makefile", makefileText(b, context));
    _ = files.add("CMakeLists.txt", rootCmakeText(b, app_name));
    _ = files.add("pj_config.mk", pjConfigText(b, context));
    _ = files.add("tools/monitor.py", @embedFile("tools/monitor.py"));

    addSideMain(b, files, "ap", opts.ap);
    addSideMain(b, files, "cp", opts.cp);
    addSideRuntimeBindings(b, files, "ap");
    addSideRuntimeBindings(b, files, "cp");
    _ = files.add("ap/CMakeLists.txt", sideCmakeText(b, "ap", app_name, context, opts.ap, opts));
    _ = files.add("cp/CMakeLists.txt", sideCmakeText(b, "cp", app_name, context, opts.cp, opts));
    addSideComponents(b, files, "ap", opts.ap, prepare_toolchain);
    addSideComponents(b, files, "cp", opts.cp, prepare_toolchain);

    addSideConfig(b, files, "ap", context.ap_target, opts.ap, opts);
    addSideConfig(b, files, "cp", context.cp_target, opts.cp, opts);

    addPartitionFiles(b, files, context, opts);

    return files.getDirectory();
}

fn addSideRuntimeBindings(b: *std.Build, files: *std.Build.Step.WriteFile, side: []const u8) void {
    _ = files.add(b.fmt("{s}/grt_net_binding.c", .{side}), @embedFile("../grt/net/binding.c"));
    if (std.mem.eql(u8, side, "ap")) {
        _ = files.add(b.fmt("{s}/bk_embed_adc_binding.c", .{side}), @embedFile("../embed/adc_binding.c"));
        _ = files.add(b.fmt("{s}/bk_embed_gpio_button_binding.c", .{side}), @embedFile("../embed/gpio_button_binding.c"));
        _ = files.add(b.fmt("{s}/bk_embed_bt_local_hci.c", .{side}), @embedFile("../embed/bt/local_hci.c"));
        _ = files.add(b.fmt("{s}/bk_embed_wifi_sta_binding.c", .{side}), @embedFile("../embed/wifi/sta_binding.c"));
        _ = files.add(b.fmt("{s}/bk_embed_audio_onboard_speaker.c", .{side}), @embedFile("../embed/audio/onboard_speaker_binding.c"));
        _ = files.add(b.fmt("{s}/bk_embed_display_qspi_binding.c", .{side}), @embedFile("../embed/display/qspi_binding.c"));
        _ = files.add(b.fmt("{s}/bk_embed_display_rgb_binding.c", .{side}), @embedFile("../embed/display/rgb_binding.c"));
        _ = files.add(b.fmt("{s}/bk_embed_touch_binding.c", .{side}), @embedFile("../embed/touch/touch_binding.c"));
    }
}

fn addSideComponents(
    b: *std.Build,
    files: *std.Build.Step.WriteFile,
    side: []const u8,
    side_opts: anytype,
    prepare_toolchain: *std.Build.Step,
) void {
    if (!@hasField(@TypeOf(side_opts), "components")) return;

    const components = @field(side_opts, "components");
    inline for (components) |component| {
        addSideComponent(b, files, side, component, prepare_toolchain);
    }
}

fn addSideComponent(
    b: *std.Build,
    files: *std.Build.Step.WriteFile,
    side: []const u8,
    component: Component,
    prepare_toolchain: *std.Build.Step,
) void {
    const root = b.fmt("{s}/components/{s}", .{ side, component.name });
    if (component.c_source_file) |source| {
        _ = files.addCopyFile(source, b.fmt("{s}/{s}.c", .{ root, component.name }));
    } else {
        _ = files.add(b.fmt("{s}/dummy.c", .{root}), "void bk_zig_component_dummy(void) {}\n");
    }

    for (component.include_dirs, 0..) |include_dir, idx| {
        _ = files.addCopyDirectory(include_dir, b.fmt("{s}/include_{d}", .{ root, idx }), .{});
    }

    for (component.archive_files.items) |archive| {
        _ = files.addCopyFile(archive.file, b.fmt("{s}/{s}", .{ root, archive.relative_path }));
    }

    for (component.artifacts.items) |artifact| {
        artifact.step.dependOn(prepare_toolchain);
        if (artifact.kind == .obj) {
            _ = files.addCopyFile(artifact.getEmittedBin(), b.fmt("{s}/obj/{s}.o", .{ root, artifact.name }));
        } else {
            _ = files.addCopyFile(artifact.getEmittedBin(), b.fmt("{s}/lib/lib{s}.a", .{ root, artifact.name }));
        }
    }

    _ = files.add(b.fmt("{s}/CMakeLists.txt", .{root}), sideComponentCmakeText(b, component));
}

fn sideComponentCmakeText(b: *std.Build, component: Component) []const u8 {
    var text = std.array_list.Managed(u8).init(b.allocator);
    const writer = text.writer();

    writer.writeAll(
        \\set(incs .)
        \\set(srcs
        \\
    ) catch @panic("OOM");
    if (component.c_source_file == null) {
        writer.writeAll(
            \\    dummy.c
            \\
        ) catch @panic("OOM");
    } else {
        writer.print(
            \\    {s}.c
            \\
        , .{component.name}) catch @panic("OOM");
    }
    writer.writeAll(")\n") catch @panic("OOM");

    for (component.include_dirs, 0..) |_, idx| {
        writer.print("list(APPEND incs include_{d})\n", .{idx}) catch @panic("OOM");
    }

    writer.writeAll(
        \\
        \\armino_component_register(SRCS "${srcs}" INCLUDE_DIRS "${incs}"
        \\
    ) catch @panic("OOM");
    if (component.requires.len != 0) {
        writer.writeAll("    PRIV_REQUIRES") catch @panic("OOM");
        for (component.requires) |require| {
            writer.print(" {s}", .{require}) catch @panic("OOM");
        }
        writer.writeAll("\n") catch @panic("OOM");
    }
    writer.writeAll(")\n") catch @panic("OOM");

    if (std.mem.eql(u8, component.name, "lvgl")) {
        writer.writeAll("target_compile_definitions(${COMPONENT_LIB} PRIVATE LV_CONF_INCLUDE_SIMPLE=1)\n") catch @panic("OOM");
    }

    var archive_idx: usize = 0;
    for (component.archive_files.items) |archive| {
        writer.print(
            \\
            \\add_prebuilt_library({s}_archive_{d} "${{CMAKE_CURRENT_LIST_DIR}}/{s}")
            \\target_link_libraries(${{COMPONENT_LIB}} INTERFACE {s}_archive_{d})
            \\
        , .{ component.name, archive_idx, archive.relative_path, component.name, archive_idx }) catch @panic("OOM");
        archive_idx += 1;
    }
    for (component.artifacts.items) |artifact| {
        if (artifact.kind == .obj) {
            writer.print(
                \\
                \\set_source_files_properties("${{CMAKE_CURRENT_LIST_DIR}}/obj/{s}.o" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
                \\target_sources(${{COMPONENT_LIB}} PRIVATE "${{CMAKE_CURRENT_LIST_DIR}}/obj/{s}.o")
                \\
            , .{ artifact.name, artifact.name }) catch @panic("OOM");
        } else {
            writer.print(
                \\
                \\add_prebuilt_library({s}_archive_{d} "${{CMAKE_CURRENT_LIST_DIR}}/lib/lib{s}.a")
                \\target_link_libraries(${{COMPONENT_LIB}} INTERFACE {s}_archive_{d})
                \\
            , .{ component.name, archive_idx, artifact.name, component.name, archive_idx }) catch @panic("OOM");
            archive_idx += 1;
        }
    }

    return text.toOwnedSlice() catch @panic("OOM");
}

fn addPartitionFiles(b: *std.Build, files: *std.Build.Step.WriteFile, context: BuildContext, opts: anytype) void {
    const auto_path = b.fmt("partitions/{s}/auto_partitions.csv", .{context.chip});
    const ram_regions_path = b.fmt("partitions/{s}/ram_regions.csv", .{context.chip});

    if (copyPartitionFileIfPresent(files, opts, "auto", auto_path)) {} else {
        if (@hasField(@TypeOf(opts), "partition_table")) {
            const text = PartitionTable.renderCsv(b.allocator, opts.partition_table) catch @panic("failed to render BK partition table");
            _ = files.add(auto_path, text);
        } else {
            @compileError("BK app options must pass .partition_table, normally from build_config.zig");
        }
    }

    if (copyPartitionFileIfPresent(files, opts, "ram_regions", ram_regions_path)) {} else {
        if (@hasField(@TypeOf(opts), "ram_regions")) {
            const text = RamRegions.renderCsv(b.allocator, opts.ram_regions) catch @panic("failed to render BK RAM regions");
            _ = files.add(ram_regions_path, text);
        } else {
            @compileError("BK app options must pass .ram_regions, normally from build_config.zig");
        }
    }
}

fn copyPartitionFileIfPresent(
    files: *std.Build.Step.WriteFile,
    opts: anytype,
    comptime field_name: []const u8,
    output_path: []const u8,
) bool {
    if (!@hasField(@TypeOf(opts), "partitions")) return false;
    const partitions = @field(opts, "partitions");
    if (!@hasField(@TypeOf(partitions), field_name)) return false;
    const partition_file = @field(partitions, field_name);

    switch (@typeInfo(@TypeOf(partition_file))) {
        .optional => if (partition_file) |path| {
            _ = files.addCopyFile(path, output_path);
            return true;
        },
        else => {
            _ = files.addCopyFile(partition_file, output_path);
            return true;
        },
    }
    return false;
}

fn makefileText(b: *std.Build, context: BuildContext) []const u8 {
    return b.fmt(
        \\SDK_DIR ?= {s}
        \\
        \\PROJECT_MAKE_FILE := $(SDK_DIR)/tools/build_tools/build_files/project_main.mk
        \\
        \\include $(PROJECT_MAKE_FILE)
        \\
    , .{context.armino_path});
}

fn rootCmakeText(b: *std.Build, app_name: []const u8) []const u8 {
    return b.fmt(
        \\cmake_minimum_required(VERSION 3.5)
        \\
        \\include($ENV{{ARMINO_TOOLS_PATH}}/build_tools/cmake/project.cmake)
        \\project({s})
        \\
    , .{app_name});
}

fn pjConfigText(b: *std.Build, context: BuildContext) []const u8 {
    if (context.toolchain_path.len == 0) return "";
    return b.fmt(
        \\GNU_TOOLCHAIN_PATH ?= {s}
        \\COMPILER_TOOLCHAIN_PATH := $(GNU_TOOLCHAIN_PATH)
        \\
    , .{context.toolchain_path});
}

fn addSideConfig(
    b: *std.Build,
    files: *std.Build.Step.WriteFile,
    side: []const u8,
    target_name: []const u8,
    side_opts: anytype,
    app_opts: anytype,
) void {
    const output_path = b.fmt("{s}/config/{s}/config", .{ side, target_name });

    if (@hasField(@TypeOf(side_opts), "config_file")) {
        const config_file = @field(side_opts, "config_file");
        switch (@typeInfo(@TypeOf(config_file))) {
            .optional => if (config_file) |path| {
                _ = files.addCopyFile(path, output_path);
                return;
            },
            else => {
                _ = files.addCopyFile(config_file, output_path);
                return;
            },
        }
    }

    if (@hasField(@TypeOf(side_opts), "build_config")) {
        const build_config = @field(side_opts, "build_config");
        if (@hasDecl(build_config, "config")) {
            const base_config_text = Config.render(b.allocator, build_config.config) catch @panic("failed to render BK config");
            const config_text = appendDerivedConfig(b, side, base_config_text, app_opts);
            _ = files.add(output_path, config_text);
            addSideConfigExtras(b, files, side, target_name, build_config);
            return;
        }
    }

    if (@hasField(@TypeOf(side_opts), "config")) {
        const config_text = @field(side_opts, "config");
        switch (@typeInfo(@TypeOf(config_text))) {
            .optional => if (config_text) |text| {
                _ = files.add(output_path, text);
                return;
            },
            else => {
                _ = files.add(output_path, config_text);
                return;
            },
        }
    }

    _ = files.add(output_path, "");
}

fn addSideConfigExtras(
    b: *std.Build,
    files: *std.Build.Step.WriteFile,
    side: []const u8,
    target_name: []const u8,
    build_config: anytype,
) void {
    if (@hasDecl(build_config, "usr_gpio_cfg")) {
        _ = files.add(
            b.fmt("{s}/config/{s}/usr_gpio_cfg.h", .{ side, target_name }),
            build_config.usr_gpio_cfg,
        );
    }
}

fn appendDerivedConfig(b: *std.Build, side: []const u8, base_config_text: []const u8, app_opts: anytype) []const u8 {
    if (!@hasField(@TypeOf(app_opts), "partition_table")) return base_config_text;

    const derived_config_text = PartitionTable.renderDerivedConfig(
        b.allocator,
        app_opts.partition_table,
        parseSide(side),
    ) catch @panic("failed to render BK config derived from partition table");
    if (derived_config_text.len == 0) return base_config_text;
    return b.fmt("{s}{s}", .{ base_config_text, derived_config_text });
}

fn addSideMain(
    b: *std.Build,
    files: *std.Build.Step.WriteFile,
    side: []const u8,
    side_opts: anytype,
) void {
    const output_path = b.fmt("{s}/{s}_main.c", .{ side, side });

    if (@hasField(@TypeOf(side_opts), "c_source_file")) {
        const source_file = @field(side_opts, "c_source_file");
        switch (@typeInfo(@TypeOf(source_file))) {
            .optional => if (source_file) |path| {
                _ = files.addCopyFile(path, output_path);
                return;
            },
            else => {
                _ = files.addCopyFile(source_file, output_path);
                return;
            },
        }
    }

    _ = files.add(output_path, entryShimText(b, side));
}

fn entryShimText(b: *std.Build, side: []const u8) []const u8 {
    if (std.mem.eql(u8, side, "cp")) {
        return b.fmt(
            \\extern int zig_{s}_main(void);
            \\
            \\void _init(void) {{}}
            \\void _fini(void) {{}}
            \\
            \\int main(void)
            \\{{
            \\    return zig_{s}_main();
            \\}}
            \\
        , .{ side, side });
    }

    return b.fmt(
        \\extern int zig_{s}_main(void);
        \\
        \\int main(void)
        \\{{
        \\    return zig_{s}_main();
        \\}}
        \\
    , .{ side, side });
}

fn sideCmakeText(
    b: *std.Build,
    side: []const u8,
    app_name: []const u8,
    context: BuildContext,
    side_opts: anytype,
    app_opts: anytype,
) []const u8 {
    const lib_name = b.fmt("{s}_{s}_zig", .{ app_name, side });
    const c_sources = if (std.mem.eql(u8, side, "ap"))
        b.fmt("{s}_main.c grt_net_binding.c bk_embed_adc_binding.c bk_embed_gpio_button_binding.c bk_embed_bt_local_hci.c bk_embed_wifi_sta_binding.c bk_embed_audio_onboard_speaker.c bk_embed_display_qspi_binding.c bk_embed_display_rgb_binding.c bk_embed_touch_binding.c", .{side})
    else
        b.fmt("{s}_main.c grt_net_binding.c", .{side});
    const base_priv_requires = if (std.mem.eql(u8, side, "ap"))
        "lwip_intf_v2_1 bk_wifi bk_wifi_driver bk_netif bk_event driver bk_display multimedia media_service bk_peripheral avdk_utils bk_bluetooth audio_play audio_record"
    else
        "lwip_intf_v2_1";
    const priv_requires = b.fmt("{s}{s}", .{ base_priv_requires, sideComponentRequiresText(b, side_opts) });
    const extra_zig_options = zigBuildOptionsText(b, app_opts, side_opts);
    const extra_prebuilt_libs = sideExtraPrebuiltLibsText(b, lib_name, side_opts);
    const extra_byproducts = sideExtraPrebuiltByproductsText(b, side_opts);
    return b.fmt(
        \\set(incs .)
        \\set(srcs {s})
        \\
        \\armino_component_register(SRCS "${{srcs}}" INCLUDE_DIRS "${{incs}}" PRIV_REQUIRES {s})
        \\
        \\find_program(ZIG_EXECUTABLE zig REQUIRED)
        \\
        \\set(BK_ZIG_ROOT "{s}")
        \\set(BK_ZIG_OUT "${{CMAKE_CURRENT_BINARY_DIR}}/zig-out")
        \\set(BK_ZIG_LIB "${{BK_ZIG_OUT}}/lib/lib{s}.a")
        \\
        \\add_custom_target({s}_lib ALL
        \\    COMMAND "${{ZIG_EXECUTABLE}}" build --release=small -Darmino-sdk-path={s}{s} -p "${{BK_ZIG_OUT}}" {s}
        \\    WORKING_DIRECTORY "${{BK_ZIG_ROOT}}"
        \\    BYPRODUCTS "${{BK_ZIG_LIB}}"
        \\{s}
        \\    COMMENT "Building {s} Zig static library"
        \\    VERBATIM
        \\)
        \\add_prebuilt_library({s}_prebuilt "${{BK_ZIG_LIB}}")
        \\add_dependencies(${{COMPONENT_LIB}} {s}_lib)
        \\add_dependencies({s}_prebuilt {s}_lib)
        \\target_link_libraries(${{COMPONENT_LIB}} PUBLIC {s}_prebuilt)
        \\{s}
        \\
    , .{
        c_sources,
        priv_requires,
        context.app_root,
        lib_name,
        lib_name,
        context.armino_path,
        extra_zig_options,
        side,
        extra_byproducts,
        side,
        lib_name,
        lib_name,
        lib_name,
        lib_name,
        lib_name,
        extra_prebuilt_libs,
    });
}

fn zigBuildOptionsText(b: *std.Build, app_opts: anytype, side_opts: anytype) []const u8 {
    var text = std.array_list.Managed(u8).init(b.allocator);
    appendZigBuildOptions(&text, app_opts);
    appendZigBuildOptions(&text, side_opts);
    return text.toOwnedSlice() catch @panic("OOM");
}

fn appendZigBuildOptions(text: *std.array_list.Managed(u8), opts: anytype) void {
    if (!@hasField(@TypeOf(opts), "zig_build_options")) return;

    const options = @field(opts, "zig_build_options");
    inline for (options) |option| {
        text.writer().print(" {s}", .{option}) catch @panic("OOM");
    }
}

fn sideExtraDepsText(b: *std.Build, context: BuildContext, side_opts: anytype) []const u8 {
    if (!@hasField(@TypeOf(side_opts), "extra_source_paths")) return "";

    var text = std.array_list.Managed(u8).init(b.allocator);
    const paths = @field(side_opts, "extra_source_paths");
    inline for (paths) |path| {
        text.writer().print(
            \\        "{s}/{s}"
            \\
        , .{ context.app_root, path }) catch @panic("OOM");
    }
    return text.toOwnedSlice() catch @panic("OOM");
}

fn sideComponentRequiresText(b: *std.Build, side_opts: anytype) []const u8 {
    if (!@hasField(@TypeOf(side_opts), "components")) return "";

    var text = std.array_list.Managed(u8).init(b.allocator);
    const components = @field(side_opts, "components");
    inline for (components) |component| {
        text.writer().print(" {s}", .{component.name}) catch @panic("OOM");
    }
    return text.toOwnedSlice() catch @panic("OOM");
}

fn sideExtraPrebuiltLibsText(b: *std.Build, owner_lib_name: []const u8, side_opts: anytype) []const u8 {
    if (!@hasField(@TypeOf(side_opts), "extra_prebuilt_libs")) return "";

    var text = std.array_list.Managed(u8).init(b.allocator);
    const libs = @field(side_opts, "extra_prebuilt_libs");
    inline for (libs) |lib| {
        const target_name = b.fmt("{s}_{s}_prebuilt", .{ owner_lib_name, lib });
        text.writer().print(
            \\set({s}_PATH "${{BK_ZIG_OUT}}/lib/lib{s}.a")
            \\add_prebuilt_library({s} "${{{s}_PATH}}")
            \\add_dependencies({s} {s}_lib)
            \\target_link_libraries(${{COMPONENT_LIB}} PUBLIC {s})
            \\
        , .{
            target_name,
            lib,
            target_name,
            target_name,
            target_name,
            owner_lib_name,
            target_name,
        }) catch @panic("OOM");
    }
    return text.toOwnedSlice() catch @panic("OOM");
}

fn sideExtraPrebuiltByproductsText(b: *std.Build, side_opts: anytype) []const u8 {
    if (!@hasField(@TypeOf(side_opts), "extra_prebuilt_libs")) return "";

    var text = std.array_list.Managed(u8).init(b.allocator);
    const libs = @field(side_opts, "extra_prebuilt_libs");
    if (libs.len == 0) return "";

    text.writer().writeAll(
        \\    BYPRODUCTS
        \\
    ) catch @panic("OOM");
    inline for (libs) |lib| {
        text.writer().print(
            \\        "${{BK_ZIG_OUT}}/lib/lib{s}.a"
            \\
        , .{lib}) catch @panic("OOM");
    }
    return text.toOwnedSlice() catch @panic("OOM");
}

fn addFlashStep(b: *std.Build, context: BuildContext, firmware_bin: []const u8, package_dependency: *std.Build.Step, opts: anytype) *std.Build.Step {
    const port = context.port orelse {
        return &b.addFail("missing serial port; pass -Dport=<device> for flash").step;
    };
    if (context.loader_path.len == 0) {
        return &b.addFail("missing bk_loader executable; pass -Dbk-loader-path=<path> or set BK_LOADER_PATH").step;
    }
    const littlefs_image_count = countLittlefsImages(opts);
    const app_reboot = littlefs_image_count == 0;
    const log_path = b.pathJoin(&.{ context.logs_dir, "bk_loader_flash.log" });
    const run = b.addSystemCommand(&.{
        context.loader_path,
        "--log_path",
        log_path,
        "--log_level",
        "3",
        "download",
        "-p",
        port,
        "-b",
        b.fmt("{d}", .{context.flash_baud}),
        "--reset_type",
        b.fmt("{d}", .{context.reset_type}),
        "--reset_baudrate",
        b.fmt("{d}", .{context.reset_baud}),
        "-g",
        "100",
        "-e",
        "1",
        "-i",
        firmware_bin,
        "-s",
        "0x0",
        "-d",
        "3",
    });
    if (app_reboot) {
        run.addArg("-r");
    }
    run.step.dependOn(package_dependency);
    return addLittlefsFlashSteps(b, context, port, opts, &run.step);
}

fn addStageFirmwareStep(
    b: *std.Build,
    context: BuildContext,
    project: std.Build.LazyPath,
    firmware_bin: []const u8,
    package_dependency: *std.Build.Step,
) *std.Build.Step {
    const output_dir = std.fs.path.dirname(firmware_bin).?;
    const script = b.fmt(
        \\set -eu
        \\mkdir -p '{s}'
        \\src="$(find 'build/{s}' -path '*/package/all-app.bin' -print -quit)"
        \\if [ -z "$src" ]; then
        \\  echo "BK package did not produce all-app.bin" >&2
        \\  exit 1
        \\fi
        \\cp "$src" '{s}'
        \\
    , .{ output_dir, context.chip, firmware_bin });
    const run = b.addSystemCommand(&.{ "sh", "-c", script });
    run.setCwd(project);
    run.step.dependOn(package_dependency);
    return &run.step;
}

fn addMonitorStep(
    b: *std.Build,
    context: BuildContext,
    project: std.Build.LazyPath,
    prepare_python: *std.Build.Step,
) *std.Build.Step {
    const port = context.port orelse {
        return &b.addFail("missing serial port; pass -Dport=<device> for monitor").step;
    };
    const python = b.pathJoin(&.{ context.python_path_dir, "python3" });
    const run = b.addSystemCommand(&.{python});
    run.addFileArg(project.path(b, "tools/monitor.py"));
    run.addArgs(&.{
        "--port",
        port,
        "--baud",
        b.fmt("{d}", .{context.reset_baud}),
    });
    run.step.dependOn(prepare_python);
    return &run.step;
}

fn addLittlefsFlashSteps(
    b: *std.Build,
    context: BuildContext,
    port: []const u8,
    opts: anytype,
    dependency: *std.Build.Step,
) *std.Build.Step {
    if (!@hasField(@TypeOf(opts), "partition_table")) return dependency;

    var previous = dependency;
    const image_count = countLittlefsImages(opts);
    if (image_count == 0) return previous;

    var index: usize = 0;
    for (opts.partition_table.entries) |entry| {
        const entry_data = entry.data orelse continue;
        switch (entry_data) {
            .littlefs => |littlefs| {
                const offset = entry.offset orelse {
                    @panic("BK LittleFS partition must set an explicit .offset so flash can place the image");
                };
                const image = addLittlefsImageStep(b, context, entry, littlefs);
                const reboot = index + 1 == image_count;
                const flash = addPartitionFlashCommand(
                    b,
                    context,
                    port,
                    image.path,
                    offset,
                    reboot,
                    b.fmt("bk_loader_littlefs_{s}.log", .{entry.name}),
                );
                flash.dependOn(previous);
                flash.dependOn(image.step);
                previous = flash;
                index += 1;
            },
            else => {},
        }
    }

    return previous;
}

const GeneratedImage = struct {
    path: []const u8,
    step: *std.Build.Step,
};

fn addLittlefsImageStep(
    b: *std.Build,
    context: BuildContext,
    entry: PartitionTable.Partition,
    littlefs: PartitionTable.LittlefsOptions,
) GeneratedImage {
    const size = PartitionTable.sizeBytes(entry.size) catch {
        @panic("BK LittleFS partition must use a numeric size or a parseable raw size");
    };
    const image_dir = b.pathJoin(&.{ context.armino_build_dir, "littlefs" });
    const image_path = b.pathJoin(&.{ image_dir, b.fmt("{s}.bin", .{entry.name}) });
    const source_dir = absoluteOrAppPath(b, context, littlefs.source_dir);
    const script = b.fmt(
        \\set -eu
        \\mkdir -p {s}
        \\{s} -c {s} -b {d} -p {d} -s {d} {s}
        \\
    , .{
        shQuote(b, image_dir),
        shQuote(b, context.mklittlefs_path),
        shQuote(b, source_dir),
        littlefs.block_size,
        littlefs.page_size,
        size,
        shQuote(b, image_path),
    });
    const run = b.addSystemCommand(&.{ "sh", "-c", script });
    run.step.dependOn(addPrepareMklittlefsStep(b, context));
    return .{
        .path = image_path,
        .step = &run.step,
    };
}

fn addPartitionFlashCommand(
    b: *std.Build,
    context: BuildContext,
    port: []const u8,
    image_path: []const u8,
    offset: u32,
    reboot: bool,
    log_file_name: []const u8,
) *std.Build.Step {
    const log_path = b.pathJoin(&.{ context.logs_dir, log_file_name });
    const run = b.addSystemCommand(&.{
        context.loader_path,
        "--log_path",
        log_path,
        "--log_level",
        "3",
        "download",
        "-p",
        port,
        "-b",
        b.fmt("{d}", .{context.flash_baud}),
        "--reset_type",
        b.fmt("{d}", .{context.reset_type}),
        "--reset_baudrate",
        b.fmt("{d}", .{context.reset_baud}),
        "-g",
        "100",
        "-e",
        "1",
        "-i",
        image_path,
        "-s",
        b.fmt("0x{x}", .{offset}),
        "-d",
        "3",
    });
    if (reboot) {
        run.addArg("-r");
    }
    return &run.step;
}

fn countLittlefsImages(opts: anytype) usize {
    if (!@hasField(@TypeOf(opts), "partition_table")) return 0;
    var count: usize = 0;
    for (opts.partition_table.entries) |entry| {
        const entry_data = entry.data orelse continue;
        switch (entry_data) {
            .littlefs => count += 1,
            else => {},
        }
    }
    return count;
}

fn absoluteOrAppPath(b: *std.Build, context: BuildContext, path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return b.pathJoin(&.{ context.app_root, path });
}

fn parseSide(side: []const u8) PartitionTable.Side {
    if (std.mem.eql(u8, side, "ap")) return .ap;
    if (std.mem.eql(u8, side, "cp")) return .cp;
    @panic("unknown BK side");
}

fn prependPath(b: *std.Build, path_dir: []const u8) []const u8 {
    const current_path = std.process.getEnvVarOwned(b.allocator, "PATH") catch "";
    if (current_path.len == 0) return path_dir;
    return b.fmt("{s}{c}{s}", .{ path_dir, std.fs.path.delimiter, current_path });
}

fn shQuote(b: *std.Build, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(b.allocator, '\'') catch @panic("out of memory");
    for (text) |c| {
        if (c == '\'') {
            out.appendSlice(b.allocator, "'\\''") catch @panic("out of memory");
        } else {
            out.append(b.allocator, c) catch @panic("out of memory");
        }
    }
    out.append(b.allocator, '\'') catch @panic("out of memory");
    return out.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

fn optionOrDefault(opts: anytype, comptime field_name: []const u8, default: []const u8) []const u8 {
    if (@hasField(@TypeOf(opts), field_name)) return @field(opts, field_name);
    return default;
}
