//! BuildContext centralizes the build-time facts needed by ESP-IDF app steps.
//!
//! Purpose:
//! - provide stable module references and target/toolchain metadata
//! - define where generated files, staged projects, and final outputs live
//! - give build steps and host tools one shared source of truth for paths
//!
//! Typical usage:
//! 1. call `resolveBuildContext()` from `build.zig`
//! 2. pass the resulting `BuildContext` into `idf.addApp()`
//! 3. have steps/tools read paths from the context instead of re-deriving them
//!
//! `BuildContext.extract()` is available when a host tool or another layer needs
//! a lean, string-only snapshot of the resolved filesystem layout.

const builtin = @import("builtin");
const std = @import("std");
const chip_mod = @import("build_context/chip.zig");

const Self = @This();

pub const ToolchainSysroot = chip_mod.ToolchainSysroot;
pub const BuildContext = Self;

/// App-specific build profile module that defines board/config/partition inputs.
build_config_module: *std.Build.Module,

/// ESP-specific glib runtime implementation module.
grt_module: *std.Build.Module,

/// Public ESP-IDF Zig module used by build helpers and generated tools.
esp_idf_module: *std.Build.Module,

/// Root of the `esp-zig` package.
esp_zig_root: std.Build.LazyPath,

/// External ESP-IDF checkout path resolved from build options or the environment.
idf_path: []const u8,

/// Absolute or workspace-relative path to the resolved `idf.py` executable.
idf_py_executable_path: []const u8,

/// Absolute path to the Python interpreter inside the resolved ESP-IDF env.
python_executable_path: []const u8,

/// Environment variables exported by ESP-IDF for downstream subprocesses.
idf_env: []const EnvironmentVariable,

/// Workspace-relative root of the user app being built.
app_root: []const u8,

/// Workspace-relative root directory that contains all build outputs.
build_dir: []const u8,

/// Workspace-relative ESP-IDF build directory created by `idf.py -B`.
idf_build_dir: []const u8,

/// Workspace-relative staged IDF project directory created by `idf.addApp()`.
idf_project_dir: []const u8,

/// Process working directory used when invoking `idf.py` inside the staged app.
idf_project_cwd: []const u8,

/// `idf.py -B` argument used from `idf_project_cwd`.
idf_build_arg: []const u8,

/// Generated sdkconfig output path written before running `idf.py`.
sdkconfig_output_path: []const u8,

/// `idf.py`-relative argument that points at the generated sdkconfig file.
sdkconfig_idf_arg: []const u8,

/// Generated partition table CSV path written before running `idf.py`.
partition_table_output_path: []const u8,

/// `idf.py`-relative argument that points at the generated partition table CSV.
partition_table_idf_arg: []const u8,

/// Generated `main/app_main.generated.c` path inside the staged IDF project.
app_main_output_path: []const u8,

/// Directory where exported flash outputs are collected for downstream steps.
binary_output_dir: []const u8,

/// Final combined flash image output path.
combined_binary_output_path: []const u8,

/// Captured ELF layout report output path.
elf_layout_output_path: []const u8,

/// Resolved chip name derived from the app build config.
chip: []const u8,

/// Final Zig target used for the embedded build.
target: std.Build.ResolvedTarget,

/// Optional toolchain sysroot resolved for the selected chip and ESP-IDF setup.
toolchain_sysroot: ?ToolchainSysroot,

pub const Extracted = struct {
    esp_root: []const u8,
    esp_idf: []const u8,
    idf_py_executable_path: []const u8,
    python_executable_path: []const u8,
    app_root: []const u8,
    build_dir: []const u8,
    idf_build_dir: []const u8,
    idf_project_dir: []const u8,
    idf_project_cwd: []const u8,
    idf_build_arg: []const u8,
    sdkconfig_output_path: []const u8,
    sdkconfig_idf_arg: []const u8,
    partition_table_output_path: []const u8,
    partition_table_idf_arg: []const u8,
    app_main_output_path: []const u8,
    output_dir: []const u8,
    combine_output_path: []const u8,
    elf_layout_output_path: []const u8,
    chip: []const u8,
};

pub const ResolveOptions = struct {
    build_config: *std.Build.Module,
    esp_dep: ?*std.Build.Dependency = null,
    app_root: []const u8 = ".",
    build_dir: []const u8 = ".build",
};
pub const ResolveBuildContextOptions = ResolveOptions;
pub const resolveBuildContext = resolve;
pub const EnvironmentVariable = struct {
    name: []const u8,
    value: []const u8,
};

pub fn resolve(
    b: *std.Build,
    opts: ResolveOptions,
) Self {
    const partition_file_name = "partitions.generated.csv";
    const build_dir = b.dupe(opts.build_dir);
    const idf_build_dir = b.pathJoin(&.{ build_dir, "idf" });
    const project_dir = b.pathJoin(&.{ build_dir, "idf_project" });
    const binary_output_dir = b.pathJoin(&.{ build_dir, "out" });
    const sdkconfig_output_path = b.pathJoin(&.{ build_dir, "sdkconfig.generated" });
    const partition_table_output_path = b.pathJoin(&.{ build_dir, partition_file_name });
    const esp_dep = opts.esp_dep orelse b.dependency("esp", .{});
    const grt_module = esp_dep.module("esp_grt");
    grt_module.addImport("build_config", opts.build_config);
    grt_module.addImport("esp_idf", esp_dep.module("esp_idf"));
    const processed_build_config = processBuildConfig(
        b,
        opts.build_config,
        esp_dep.module("esp_idf"),
    );
    const maybe_idf_path = b.option(
        []const u8,
        "idf",
        "ESP-IDF root directory; defaults to IDF_PATH env var",
    ) orelse
        getEnvOrNull(b, "IDF_PATH") orelse
        getEnvOrNull(b, "idf");
    const idf_path = maybe_idf_path orelse "";
    const esp_root = esp_dep.path("");
    const idf_py_executable_path = if (idf_path.len == 0)
        ""
    else
        b.pathJoin(&.{ idf_path, "tools", "idf.py" });
    const resolved_idf_env = if (idf_path.len == 0)
        ResolvedIdfEnvironment{
            .variables = &.{},
            .python_executable_path = "",
        }
    else
        resolveIdfEnvironment(
            b,
            esp_root.path(b, "lib/idf/tools/idf_env.py").getPath(b),
            idf_path,
        );
    const toolchain_sysroot = resolveToolchainSysroot(
        b,
        processed_build_config.chip,
        idf_path,
        resolved_idf_env.variables,
    );
    return .{
        .build_config_module = opts.build_config,
        .grt_module = grt_module,
        .esp_idf_module = esp_dep.module("esp_idf"),
        .esp_zig_root = esp_root,
        .idf_path = idf_path,
        .idf_py_executable_path = idf_py_executable_path,
        .python_executable_path = resolved_idf_env.python_executable_path,
        .idf_env = resolved_idf_env.variables,
        .app_root = b.dupe(opts.app_root),
        .build_dir = build_dir,
        .idf_build_dir = idf_build_dir,
        .idf_project_dir = project_dir,
        .idf_project_cwd = joinAppRoot(b, opts.app_root, project_dir),
        .idf_build_arg = "../idf",
        .sdkconfig_output_path = sdkconfig_output_path,
        .sdkconfig_idf_arg = "../sdkconfig.generated",
        .partition_table_output_path = partition_table_output_path,
        .partition_table_idf_arg = b.fmt("../{s}", .{partition_file_name}),
        .app_main_output_path = b.pathJoin(&.{ project_dir, "main", "app_main.generated.c" }),
        .binary_output_dir = binary_output_dir,
        .combined_binary_output_path = b.pathJoin(&.{ binary_output_dir, "combined.bin" }),
        .elf_layout_output_path = b.pathJoin(&.{ build_dir, "elf_layout.txt" }),
        .chip = processed_build_config.chip,
        .target = chip_mod.resolveChipTarget(b, processed_build_config.chip),
        .toolchain_sysroot = toolchain_sysroot,
    };
}

pub fn extract(context: Self, b: *std.Build) Extracted {
    return .{
        .esp_root = b.dupe(context.esp_zig_root.getPath(b)),
        .esp_idf = b.dupe(context.idf_path),
        .idf_py_executable_path = b.dupe(context.idf_py_executable_path),
        .python_executable_path = b.dupe(context.python_executable_path),
        .app_root = b.dupe(context.app_root),
        .build_dir = b.dupe(context.build_dir),
        .idf_build_dir = b.dupe(context.idf_build_dir),
        .idf_project_dir = b.dupe(context.idf_project_dir),
        .idf_project_cwd = b.dupe(context.idf_project_cwd),
        .idf_build_arg = b.dupe(context.idf_build_arg),
        .sdkconfig_output_path = b.dupe(context.sdkconfig_output_path),
        .sdkconfig_idf_arg = b.dupe(context.sdkconfig_idf_arg),
        .partition_table_output_path = b.dupe(context.partition_table_output_path),
        .partition_table_idf_arg = b.dupe(context.partition_table_idf_arg),
        .app_main_output_path = b.dupe(context.app_main_output_path),
        .output_dir = b.dupe(context.binary_output_dir),
        .combine_output_path = b.dupe(context.combined_binary_output_path),
        .elf_layout_output_path = b.dupe(context.elf_layout_output_path),
        .chip = b.dupe(context.chip),
    };
}

pub fn applyIdfEnvironment(context: Self, run: *std.Build.Step.Run) void {
    for (context.idf_env) |entry| {
        run.setEnvironmentVariable(entry.name, entry.value);
    }
}

const ProcessedBuildConfig = struct {
    chip: []const u8,
};

const PythonCommand = struct {
    program: []const u8,
    first_arg: ?[]const u8 = null,

    fn appendTo(self: PythonCommand, allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8)) !void {
        try argv.append(allocator, self.program);
        if (self.first_arg) |arg| {
            try argv.append(allocator, arg);
        }
    }
};

const ResolvedIdfEnvironment = struct {
    variables: []const EnvironmentVariable,
    python_executable_path: []const u8,
};

fn processBuildConfig(
    b: *std.Build,
    build_config_module: *std.Build.Module,
    idf_module: *std.Build.Module,
) ProcessedBuildConfig {
    const build_config_path = moduleRootSourcePath(b, build_config_module, "build_config");
    const probe_key = std.hash.Wyhash.hash(0, build_config_path);
    b.cache_root.handle.makePath("espz-probe") catch @panic("failed to create espz-probe cache dir");
    const probe_source_path = b.cache_root.join(
        b.allocator,
        &.{ "espz-probe", b.fmt("process_build_config.{x}.zig", .{probe_key}) },
    ) catch @panic("OOM");
    const probe_bin_path = b.cache_root.join(
        b.allocator,
        &.{ "espz-probe", b.fmt("process_build_config.{x}", .{probe_key}) },
    ) catch @panic("OOM");
    const probe_source = std.fmt.allocPrint(
        b.allocator,
        \\const std = @import("std");
        \\const build_config = @import("build_config");
        \\
        \\pub fn main() !void {{
        \\    const stdout = std.fs.File.stdout();
        \\    _ = build_config.partition_table;
        \\    _ = build_config.sdk_config;
        \\    try stdout.writeAll("chip=");
        \\    try stdout.writeAll(build_config.chip);
        \\    try stdout.writeAll("\n");
        \\}}
        \\
    ,
        .{},
    ) catch @panic("OOM");
    defer b.allocator.free(probe_source);
    std.fs.cwd().writeFile(.{
        .sub_path = probe_source_path,
        .data = probe_source,
    }) catch |err| {
        std.debug.panic("failed to write build_config component probe source '{s}': {}", .{ probe_source_path, err });
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(b.allocator);
    var owned_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_args.items) |arg| b.allocator.free(arg);
        owned_args.deinit(b.allocator);
    }

    argv.appendSlice(b.allocator, &.{
        b.graph.zig_exe,
        "build-exe",
        "-OReleaseSafe",
        "--name",
        "espz_process_build_config",
        "--dep",
        "build_config",
        "--dep",
        "esp_idf",
    }) catch @panic("OOM");
    appendFmtArg(b, &argv, &owned_args, "-Mroot={s}", .{probe_source_path});
    for (build_config_module.import_table.keys(), build_config_module.import_table.values()) |name, imported_module| {
        argv.appendSlice(b.allocator, &.{ "--dep", name }) catch @panic("OOM");
        if (std.mem.eql(u8, name, "esp_idf")) continue;
        appendFmtArg(
            b,
            &argv,
            &owned_args,
            "-M{s}={s}",
            .{ name, moduleRootSourcePath(b, imported_module, name) },
        );
    }
    appendFmtArg(b, &argv, &owned_args, "-Mbuild_config={s}", .{build_config_path});
    appendFmtArg(
        b,
        &argv,
        &owned_args,
        "-Mesp_idf={s}",
        .{moduleRootSourcePath(b, idf_module, "esp_idf")},
    );
    if (b.cache_root.path) |path| {
        argv.appendSlice(b.allocator, &.{ "--cache-dir", path }) catch @panic("OOM");
    }
    if (b.graph.global_cache_root.path) |path| {
        argv.appendSlice(b.allocator, &.{ "--global-cache-dir", path }) catch @panic("OOM");
    }
    if (b.graph.zig_lib_directory.path) |path| {
        argv.appendSlice(b.allocator, &.{ "--zig-lib-dir", path }) catch @panic("OOM");
    }
    appendFmtArg(b, &argv, &owned_args, "-femit-bin={s}", .{probe_bin_path});

    const compile_result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = argv.items,
        .env_map = &b.graph.env_map,
        .max_output_bytes = 128 * 1024,
    }) catch |err| {
        std.debug.panic("failed to compile build_config probe: {}", .{err});
    };
    defer b.allocator.free(compile_result.stdout);
    defer b.allocator.free(compile_result.stderr);
    switch (compile_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.panic(
                "failed to compile build_config probe for '{s}':\n{s}",
                .{ build_config_path, compile_result.stderr },
            );
        },
        else => std.debug.panic("build_config probe compiler terminated unexpectedly", .{}),
    }

    const run_result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{probe_bin_path},
        .env_map = &b.graph.env_map,
        .max_output_bytes = 32 * 1024,
    }) catch |err| {
        std.debug.panic("failed to run build_config probe: {}", .{err});
    };
    defer b.allocator.free(run_result.stdout);
    defer b.allocator.free(run_result.stderr);
    switch (run_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.panic(
                "failed to read build_config info from '{s}':\n{s}",
                .{ build_config_path, run_result.stderr },
            );
        },
        else => std.debug.panic("build_config probe terminated unexpectedly", .{}),
    }

    var chip: ?[]const u8 = null;
    var iter = std.mem.splitScalar(u8, run_result.stdout, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "chip=")) {
            const value = trimmed["chip=".len..];
            if (value.len == 0) {
                std.debug.panic("build_config chip is empty in '{s}'", .{build_config_path});
            }
            chip = b.allocator.dupe(u8, value) catch @panic("OOM");
            continue;
        }
        std.debug.panic(
            "unexpected build_config probe output line for '{s}': {s}",
            .{ build_config_path, trimmed },
        );
    }
    return .{
        .chip = chip orelse std.debug.panic(
            "missing chip in build_config probe for '{s}'",
            .{build_config_path},
        ),
    };
}

fn moduleRootSourcePath(
    b: *std.Build,
    module: *std.Build.Module,
    module_name: []const u8,
) []const u8 {
    const root = module.root_source_file orelse
        std.debug.panic("module '{s}' must have a root_source_file", .{module_name});
    return root.getPath(b);
}

fn appendFmtArg(
    b: *std.Build,
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const arg = std.fmt.allocPrint(b.allocator, fmt, args) catch @panic("OOM");
    owned_args.append(b.allocator, arg) catch @panic("OOM");
    argv.append(b.allocator, arg) catch @panic("OOM");
}

fn joinAppRoot(
    b: *std.Build,
    app_root: []const u8,
    relative_path: []const u8,
) []const u8 {
    if (app_root.len == 0 or std.mem.eql(u8, app_root, ".")) {
        return b.dupe(relative_path);
    }
    return b.pathJoin(&.{ app_root, relative_path });
}

fn getEnvOrNull(b: *std.Build, name: []const u8) ?[]const u8 {
    const value = std.process.getEnvVarOwned(b.allocator, name) catch return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) {
        return null;
    }
    return trimmed;
}

fn resolveToolchainSysroot(
    b: *std.Build,
    chip: []const u8,
    idf_path: []const u8,
    idf_env: []const EnvironmentVariable,
) ?ToolchainSysroot {
    const resolved = blk: {
        if (idf_env.len == 0) {
            break :blk chip_mod.resolveToolchainSysroot(b, chip, &b.graph.env_map);
        }
        var env_map = createProcessEnvMap(b.allocator, &b.graph.env_map, idf_env) catch @panic("OOM");
        defer env_map.deinit();
        break :blk chip_mod.resolveToolchainSysroot(b, chip, &env_map);
    };
    return resolved orelse chip_mod.resolveToolchainSysrootBySourcingIdf(b, chip, idf_path);
}

fn resolveIdfEnvironment(
    b: *std.Build,
    env_script_path: []const u8,
    idf_path: []const u8,
) ResolvedIdfEnvironment {
    const python = resolveBootstrapPythonCommand(b);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(b.allocator);
    python.appendTo(b.allocator, &argv) catch @panic("OOM");
    argv.appendSlice(b.allocator, &.{ env_script_path, "--idf-path", idf_path }) catch @panic("OOM");

    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = argv.items,
        .env_map = &b.graph.env_map,
        .max_output_bytes = 256 * 1024,
    }) catch |err| {
        std.debug.panic("failed to resolve ESP-IDF environment for '{s}': {}", .{ idf_path, err });
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            const details = if (result.stderr.len != 0) result.stderr else result.stdout;
            std.debug.panic(
                "failed to resolve ESP-IDF environment for '{s}':\n{s}",
                .{ idf_path, details },
            );
        },
        else => std.debug.panic("ESP-IDF environment resolver terminated unexpectedly for '{s}'", .{idf_path}),
    }

    const env_vars = parseEnvironmentVariables(b, env_script_path, result.stdout);
    const python_executable_path = envValueOrNull(env_vars, "ESP_ZIG_IDF_PYTHON") orelse
        std.debug.panic(
            "missing ESP_ZIG_IDF_PYTHON in ESP-IDF environment output from '{s}'",
            .{env_script_path},
        );
    return .{
        .variables = env_vars,
        .python_executable_path = b.dupe(python_executable_path),
    };
}

fn resolveBootstrapPythonCommand(b: *std.Build) PythonCommand {
    if (b.option(
        []const u8,
        "python",
        "Python interpreter used to query ESP-IDF's exported environment",
    )) |configured_python| {
        const command: PythonCommand = .{ .program = configured_python };
        ensurePythonCommandWorks(b, command, "build option -Dpython");
        return command;
    }
    if (getEnvOrNull(b, "PYTHON")) |env_python| {
        const command: PythonCommand = .{ .program = env_python };
        ensurePythonCommandWorks(b, command, "environment variable PYTHON");
        return command;
    }

    const candidates = if (builtin.os.tag == .windows)
        [_]PythonCommand{
            .{ .program = "python" },
            .{ .program = "py", .first_arg = "-3" },
        }
    else
        [_]PythonCommand{
            .{ .program = "python3" },
            .{ .program = "python" },
        };
    for (candidates) |candidate| {
        if (pythonCommandWorks(b, candidate)) return candidate;
    }
    std.debug.panic(
        "failed to locate a usable Python interpreter; set -Dpython=<path> or PYTHON=<path>",
        .{},
    );
}

fn ensurePythonCommandWorks(b: *std.Build, command: PythonCommand, source: []const u8) void {
    if (pythonCommandWorks(b, command)) return;
    std.debug.panic(
        "configured Python from {s} is not runnable: {s}",
        .{ source, command.program },
    );
}

fn pythonCommandWorks(b: *std.Build, command: PythonCommand) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(b.allocator);
    command.appendTo(b.allocator, &argv) catch return false;
    argv.appendSlice(b.allocator, &.{ "-c", "import sys; print(sys.executable)" }) catch return false;

    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = argv.items,
        .env_map = &b.graph.env_map,
        .max_output_bytes = 8 * 1024,
    }) catch return false;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0 and std.mem.trim(u8, result.stdout, " \t\r\n").len != 0,
        else => false,
    };
}

fn parseEnvironmentVariables(
    b: *std.Build,
    source: []const u8,
    output: []const u8,
) []const EnvironmentVariable {
    var vars = std.ArrayList(EnvironmentVariable).empty;
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse
            std.debug.panic(
                "unexpected ESP-IDF environment output line from '{s}': {s}",
                .{ source, trimmed },
            );
        const name = trimmed[0..eq_index];
        if (name.len == 0) {
            std.debug.panic("empty environment variable name in output from '{s}'", .{source});
        }
        vars.append(b.allocator, .{
            .name = b.dupe(name),
            .value = b.dupe(trimmed[eq_index + 1 ..]),
        }) catch @panic("OOM");
    }
    return vars.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn envValueOrNull(vars: []const EnvironmentVariable, name: []const u8) ?[]const u8 {
    for (vars) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

fn createProcessEnvMap(
    allocator: std.mem.Allocator,
    base: *const std.process.EnvMap,
    overrides: []const EnvironmentVariable,
) !std.process.EnvMap {
    var env_map = std.process.EnvMap.init(allocator);
    errdefer env_map.deinit();

    var iter = base.iterator();
    while (iter.next()) |entry| {
        try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    for (overrides) |entry| {
        try env_map.put(entry.name, entry.value);
    }
    return env_map;
}

test "parseEnvironmentVariables parses key value lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const graph: *std.Build.Graph = try arena.create(std.Build.Graph);
    graph.* = .{
        .arena = arena,
        .cache = .{
            .gpa = arena,
            .manifest_dir = std.fs.cwd(),
        },
        .zig_exe = "test",
        .env_map = std.process.EnvMap.init(arena),
        .global_cache_root = .{ .path = "test", .handle = std.fs.cwd() },
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(.{}),
        },
        .zig_lib_directory = std.Build.Cache.Directory.cwd(),
        .time_report = false,
    };
    const b = try std.Build.create(
        graph,
        .{ .path = "test", .handle = std.fs.cwd() },
        .{ .path = "test", .handle = std.fs.cwd() },
        &.{},
    );

    const vars = parseEnvironmentVariables(
        b,
        "test-env",
        "IDF_PATH=/tmp/idf\nPATH=/tmp/venv/bin:/usr/bin\nESP_ZIG_IDF_PYTHON=/tmp/venv/bin/python3\n",
    );
    try std.testing.expectEqual(@as(usize, 3), vars.len);
    try std.testing.expectEqualStrings("/tmp/idf", envValueOrNull(vars, "IDF_PATH").?);
    try std.testing.expectEqualStrings("/tmp/venv/bin/python3", envValueOrNull(vars, "ESP_ZIG_IDF_PYTHON").?);
}
