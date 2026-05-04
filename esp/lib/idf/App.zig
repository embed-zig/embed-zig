//! App wires the ESP-IDF application build graph.
//!
//! Responsibility:
//! - accept the user-facing `addApp()` inputs
//! - assemble an `idf.Project` from the app entry and other components
//! - register the compile/run steps that generate, configure, build, flash, and monitor the app
//! - connect those steps together into one executable build flow
//!
//! Related structures:
//! - `BuildContext` provides the resolved paths, toolchain info, and output locations
//! - `Project` represents the logical IDF project assembled by the app
//! - `Component` represents each source/archive-backed IDF component used by the project
//!
//! High-level flow:
//! 1. `addApp()` derives runtime options and app-local inputs.
//! 2. `addApp()` builds an `idf.Project` from the entry component and other components.
//! 3. The project is extracted into a lean form for the staged IDF project generator.
//! 4. App registers the intermediate steps:
//!    - generate sdkconfig and partition table
//!    - stage the IDF project
//!    - generate `app_main.generated.c`
//! 5. App registers the execution steps on top of that staged project:
//!    - `idf.py reconfigure`
//!    - `idf.py build`
//!    - copy flash outputs
//!    - combine flash image
//!    - flash / monitor
//! 6. App returns the resulting step handles on the `App` value itself.
//!
//! In short, `App.zig` is the orchestration layer: it builds the `Project`,
//! mounts all required compile/runtime steps, and defines the build workflow.
const std = @import("std");
const BuildContext = @import("BuildContext.zig");
const Component = @import("Component.zig");
const Project = @import("Project.zig");
const idf_commands = @import("idf_commands.zig");
const tools = @import("tools.zig");

const Self = @This();
const Module = std.Build.Module;

pub const RuntimeOptions = struct {
    port: ?[]const u8 = null,
    timeout: u32 = 15,
};

pub const Entry = struct {
    module: *Module,
    symbol: []const u8,
};

pub const AddOptions = struct {
    context: BuildContext.BuildContext,
    entry: Entry,
    components: []const *Component = &.{},
};

/// Generates `main/app_main.generated.c` for the staged IDF app.
gen_app_main: *std.Build.Step,

/// Generates `sdkconfig.generated` and `partitions.generated.csv`.
gen_sdkconfig_and_partition_table: *std.Build.Step,

/// Runs `idf.py reconfigure` inside the staged project.
sdkconfig_configure: *std.Build.Step,

/// Captures the built ELF layout into `.build/elf_layout.txt` by default.
elf_layout: *std.Build.Step,

/// Merges all flashable images into `.build/combined.bin` by default.
combine_binaries: *std.Build.Step,

/// Flashes firmware, then flashes any extra data partitions.
flash: *std.Build.Step,

/// Runs `idf.py monitor` without flashing first.
monitor: *std.Build.Step,

pub fn addApp(b: *std.Build, app_name: []const u8, opts: AddOptions) Self {
    const project = Project.create(b, opts.context, opts.entry.module, opts.components);
    const extracted_project = project.extract() catch |err| std.debug.panic(
        "failed to extract idf.Project '{s}': {s}",
        .{ app_name, @errorName(err) },
    );
    const runtime: RuntimeOptions = .{
        .port = b.option([]const u8, "port", "Serial port used by flash/monitor"),
        .timeout = b.option(u32, "timeout", "Auto-exit monitor after N seconds") orelse 15,
    };

    if (opts.context.idf_path.len == 0) {
        const fail = b.addFail("missing ESP-IDF root; set build option 'idf' or environment variable IDF_PATH");
        return Self{
            .gen_app_main = &fail.step,
            .gen_sdkconfig_and_partition_table = &fail.step,
            .sdkconfig_configure = &fail.step,
            .combine_binaries = &fail.step,
            .elf_layout = &fail.step,
            .flash = &fail.step,
            .monitor = &fail.step,
        };
    }

    // Generate `.build/idf_project/` plus sdkconfig.generated, partitions.generated.csv,
    // and app_main.generated.c

    const gen_idf_project_dir = tools.addGenerateAddappProjectTool(b, app_name, opts.context, extracted_project);
    const gen_sdkconfig_and_partition_table = tools.addSdkconfigGeneratorTool(b, opts.context);
    const gen_app_main = tools.addGenerateAppMainTool(b, opts.context, opts.entry.symbol);
    gen_app_main.dependOn(gen_idf_project_dir);

    // Second stage: configure the staged project
    const sdkconfig_configure = idf_commands.reconfigure(b, opts.context);
    sdkconfig_configure.dependOn(gen_sdkconfig_and_partition_table);
    sdkconfig_configure.dependOn(gen_idf_project_dir);
    sdkconfig_configure.dependOn(gen_app_main);

    // Third stage: build the staged project, elf layout and partition images

    const idf_build = idf_commands.build(b, opts.context);
    idf_build.dependOn(sdkconfig_configure);
    const gen_elf_layout = tools.addElfLayoutTool(b, opts.context);
    gen_elf_layout.dependOn(idf_build);
    const gen_partition_images = tools.addDataPartitionBuildTool(b, opts.context);
    gen_partition_images.dependOn(idf_build);

    // Fourth stage: copy binaries to output directory and combine them into one flashable binary

    const copy_binaries = tools.addExportFlashOutputsTool(b, opts.context, app_name);
    copy_binaries.dependOn(gen_partition_images);
    const combine_binaries = tools.addCombineFlashImageTool(b, opts.context);
    combine_binaries.dependOn(copy_binaries);

    // Fifth stage: flash the combined binary
    const flash = blk: {
        if (runtime.port) |port| {
            const step = tools.addFlashCombinedImageTool(b, opts.context, port);
            step.dependOn(combine_binaries);
            break :blk step;
        }
        break :blk &b.addFail("missing serial port; pass -Dport=<device> for flash/monitor steps").step;
    };

    // Sixth stage: monitor the serial output

    // monitor the serial output without flashing
    const monitor = blk: {
        if (runtime.port) |port| {
            const step = tools.addMonitorTool(b, opts.context, port, runtime.timeout);
            break :blk step;
        }
        break :blk &b.addFail("missing serial port; pass -Dport=<device> for flash/monitor steps").step;
    };

    return Self{
        .gen_app_main = gen_app_main,
        .gen_sdkconfig_and_partition_table = gen_sdkconfig_and_partition_table,
        .sdkconfig_configure = sdkconfig_configure,
        .combine_binaries = combine_binaries,
        .elf_layout = gen_elf_layout,
        .flash = flash,
        .monitor = monitor,
    };
}
