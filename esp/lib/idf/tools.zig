//! `idf/tools.zig` is the namespace for ESP-IDF-related build tools.
//!
//! Purpose:
//! - provide a canonical list of built-in ESP-IDF helper tools shipped in `lib/idf/tools/`
//! - register built-in host-tool commands with the right imports and arguments
//! - keep tool-specific command construction out of `App.zig`
//!
//! This file is intentionally lightweight. It defines the public namespace for
//! built-in IDF helper tools plus the shared internal builder used to compile
//! and run them.
const std = @import("std");
const BuildContext = @import("BuildContext.zig");
const Project = @import("Project.zig");

/// Named module import passed to a Zig host tool build.
const Import = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub fn addSdkconfigGeneratorTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
) *std.Build.Step {
    const grt_build_module = b.createModule(.{
        .root_source_file = context.esp_zig_root.path(b, "lib/grt/build.zig"),
    });
    const run = addBuiltinHostTool(
        b,
        "sdkconfig_generator",
        context.esp_zig_root.path(b, "lib/idf/tools/sdkconfig_generator.zig"),
        &.{
            .{ .name = "esp_idf", .module = context.esp_idf_module },
            .{ .name = "build_config", .module = context.build_config_module },
            .{ .name = "grt_build", .module = grt_build_module },
        },
    );
    run.setCwd(b.path(context.app_root));
    run.addArg(context.sdkconfig_output_path);
    run.addArg(context.partition_table_output_path);
    run.addArg(context.partition_table_idf_arg);
    run.addFileArg(.{ .cwd_relative = moduleRootSourcePath(b, context.build_config_module, "build_config") });
    return &run.step;
}

pub fn addGenerateAddappProjectTool(
    b: *std.Build,
    app_name: []const u8,
    context: BuildContext.BuildContext,
    project: Project.Extracted,
) *std.Build.Step {
    const run = addBuiltinHostTool(
        b,
        "generate_addapp_project",
        context.esp_zig_root.path(b, "lib/idf/tools/generate_addapp_project.zig"),
        &.{
            .{ .name = "esp_idf", .module = context.esp_idf_module },
            .{ .name = "build_config", .module = context.build_config_module },
        },
    );
    run.setCwd(b.path(context.app_root));
    run.addArg(context.idf_project_dir);
    run.addArg(app_name);
    run.addArg("--entry-component");
    run.addArg(project.entry_name);
    for (project.requirements) |requirement| {
        const component = requirement.component orelse continue;
        run.addArg("--source-component");
        run.addArg(component.name);
        run.addArg(b.fmt("{d}", .{component.srcs.len}));
        run.addArg(b.fmt("{d}", .{component.copy_files.len}));
        run.addArg(b.fmt("{d}", .{component.archives.len}));
        run.addArg(b.fmt("{d}", .{component.include_dirs.len}));
        run.addArg(b.fmt("{d}", .{component.requires.len}));
        run.addArg(b.fmt("{d}", .{component.priv_requires.len}));

        for (component.srcs) |src| {
            run.addArg(src.idf_project_path);
            run.addFileArg(src.original_path);
        }
        for (component.copy_files) |copy_file| {
            run.addArg(copy_file.idf_project_path);
            run.addFileArg(copy_file.original_path);
        }
        for (component.archives) |archive| {
            run.addArg(archive.idf_project_path);
            run.addFileArg(archive.original_path);
        }
        for (component.include_dirs) |include_dir| {
            run.addArg(include_dir.idf_project_path);
            run.addDirectoryArg(include_dir.original_path);
        }
        for (component.requires) |require_name| {
            run.addArg(require_name);
        }
        for (component.priv_requires) |require_name| {
            run.addArg(require_name);
        }
    }
    return &run.step;
}

pub fn addGenerateAppMainTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
    entry_symbol: []const u8,
) *std.Build.Step {
    const run = addBuiltinHostTool(
        b,
        "generate_app_main",
        context.esp_zig_root.path(b, "lib/idf/tools/generate_app_main.zig"),
        &.{},
    );
    run.setCwd(b.path(context.app_root));
    run.addArg(context.app_main_output_path);
    run.addArg(entry_symbol);
    return &run.step;
}

pub fn addDataPartitionBuildTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
) *std.Build.Step {
    const run = addBuiltinHostTool(
        b,
        "data_partitions",
        context.esp_zig_root.path(b, "lib/idf/tools/data_partitions.zig"),
        &.{
            .{ .name = "esp_idf", .module = context.esp_idf_module },
            .{ .name = "build_config", .module = context.build_config_module },
        },
    );
    context.applyIdfEnvironment(run);
    run.setCwd(b.path(context.app_root));
    run.addArg("build");
    run.addArg(context.app_root);
    run.addArg(context.build_dir);
    run.addArg(context.idf_path);
    run.addArg(context.python_executable_path);
    return &run.step;
}

pub fn addDataPartitionFlashTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
    port: ?[]const u8,
) *std.Build.Step {
    const run = addBuiltinHostTool(
        b,
        "data_partitions",
        context.esp_zig_root.path(b, "lib/idf/tools/data_partitions.zig"),
        &.{
            .{ .name = "esp_idf", .module = context.esp_idf_module },
            .{ .name = "build_config", .module = context.build_config_module },
        },
    );
    context.applyIdfEnvironment(run);
    run.setCwd(b.path(context.app_root));
    run.addArg("flash");
    run.addArg(context.app_root);
    run.addArg(context.build_dir);
    run.addArg(context.idf_path);
    run.addArg(context.python_executable_path);
    run.addArg(port orelse "");
    return &run.step;
}

pub fn addCombineFlashImageTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
) *std.Build.Step {
    const run = addBuiltinHostTool(
        b,
        "combine_flash_image",
        context.esp_zig_root.path(b, "lib/idf/tools/combine_flash_image.zig"),
        &.{
            .{ .name = "esp_idf", .module = context.esp_idf_module },
            .{ .name = "build_config", .module = context.build_config_module },
        },
    );
    context.applyIdfEnvironment(run);
    run.setCwd(b.path(context.app_root));
    run.addArg(context.app_root);
    run.addArg(context.build_dir);
    run.addArg(context.idf_path);
    run.addArg(context.python_executable_path);
    run.addArg(context.combined_binary_output_path);
    return &run.step;
}

pub fn addFlashCombinedImageTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
    port: ?[]const u8,
) *std.Build.Step {
    const run = b.addSystemCommand(&.{context.python_executable_path});
    context.applyIdfEnvironment(run);
    run.setCwd(b.path(context.app_root));
    run.addArgs(&.{ "-m", "esptool", "--chip", context.chip });
    if (port) |resolved_port| {
        run.addArgs(&.{ "--port", resolved_port });
    }
    run.addArgs(&.{ "write_flash", "0x0" });
    run.addArg(context.combined_binary_output_path);
    return &run.step;
}

pub fn addExportFlashOutputsTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
    app_name: []const u8,
) *std.Build.Step {
    const run = addBuiltinHostTool(
        b,
        "export_flash_outputs",
        context.esp_zig_root.path(b, "lib/idf/tools/export_flash_outputs.zig"),
        &.{
            .{ .name = "esp_idf", .module = context.esp_idf_module },
            .{ .name = "build_config", .module = context.build_config_module },
        },
    );
    run.setCwd(b.path(context.app_root));
    run.addArg(context.build_dir);
    run.addArg(context.binary_output_dir);
    run.addArg(app_name);
    return &run.step;
}

pub fn addMonitorTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
    port: ?[]const u8,
    timeout: u32,
) *std.Build.Step {
    const run = b.addSystemCommand(&.{context.python_executable_path});
    context.applyIdfEnvironment(run);
    run.setCwd(b.path(context.idf_project_cwd));
    run.addFileArg(context.esp_zig_root.path(b, "lib/idf/tools/pty_monitor.py"));
    run.addArg(b.fmt("--timeout={d}", .{timeout}));
    run.addArg(context.python_executable_path);
    run.addArg(context.idf_py_executable_path);
    run.addArgs(&.{ "-B", context.idf_build_arg });
    run.addArg(b.fmt("-DSDKCONFIG={s}", .{context.sdkconfig_idf_arg}));
    run.setEnvironmentVariable("SDKCONFIG", context.sdkconfig_idf_arg);
    if (port) |resolved_port| {
        run.addArgs(&.{ "-p", resolved_port });
    }
    run.addArg("monitor");
    return &run.step;
}

pub fn addSerialRunTool(
    b: *std.Build,
    app_name: []const u8,
    context: BuildContext.BuildContext,
    port: []const u8,
) *std.Build.Step {
    const run = b.addSystemCommand(&.{context.python_executable_path});
    context.applyIdfEnvironment(run);
    run.setCwd(b.path(context.app_root));
    run.addFileArg(context.esp_zig_root.path(b, "lib/idf/tools/serial_run.py"));
    run.addArg(port);
    run.setName(b.fmt("{s} serial run reset", .{app_name}));
    return &run.step;
}

pub fn addElfLayoutTool(
    b: *std.Build,
    context: BuildContext.BuildContext,
) *std.Build.Step {
    const run = addBuiltinHostTool(
        b,
        "elf_layout",
        context.esp_zig_root.path(b, "lib/idf/tools/elf_layout.zig"),
        &.{},
    );
    run.setCwd(b.path("."));
    run.addArg(context.app_root);
    run.addArg(context.build_dir);
    run.addArg(moduleRootSourcePath(b, context.build_config_module, "build_config"));
    run.addArg("");
    return &run.step;
}

fn addBuiltinHostTool(
    b: *std.Build,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    imports: []const Import,
) *std.Build.Step.Run {
    const key = computeBuiltinHostToolKey(b, name, root_source_file, imports);

    b.cache_root.handle.makePath("espz-host-tools") catch @panic("failed to create host tool cache dir");
    const output_path = b.cache_root.join(
        b.allocator,
        &.{ "espz-host-tools", b.fmt("{s}.{x}", .{ name, key }) },
    ) catch @panic("OOM");

    const compile = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-exe",
        optimizeFlag(.ReleaseSafe),
        "--name",
        name,
    });
    compile.has_side_effects = true;
    for (imports) |dep| {
        compile.addArgs(&.{ "--dep", dep.name });
    }
    compile.addPrefixedFileArg("-Mroot=", root_source_file);

    var emitted = std.ArrayList(EmittedToolModule).empty;
    defer emitted.deinit(b.allocator);
    for (imports) |dep| {
        emitToolModuleDefinition(b, compile, &emitted, dep.name, dep.module);
    }
    if (b.cache_root.path) |path| {
        compile.addArgs(&.{ "--cache-dir", path });
    }
    if (b.graph.global_cache_root.path) |path| {
        compile.addArgs(&.{ "--global-cache-dir", path });
    }
    if (b.graph.zig_lib_directory.path) |path| {
        compile.addArgs(&.{ "--zig-lib-dir", path });
    }
    compile.addArg(b.fmt("-femit-bin={s}", .{output_path}));

    const run = b.addSystemCommand(&.{output_path});
    run.step.dependOn(&compile.step);
    run.setName(name);
    return run;
}

const EmittedToolModule = struct {
    name: []const u8,
    module: *std.Build.Module,
};

const CachedModuleInfo = struct {
    fingerprint: u64,
};

const FileScopeMemo = struct {
    mutex: std.Thread.Mutex = .{},
    file_hashes: std.StringHashMapUnmanaged(u64) = .{},
    modules: std.AutoHashMapUnmanaged(usize, CachedModuleInfo) = .{},

    fn getFileHash(self: *FileScopeMemo, path: []const u8) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.file_hashes.get(path)) |hash| return hash;

        const owned_path = std.heap.page_allocator.dupe(u8, path) catch @panic("OOM");
        const hash = computeFileHash(path);
        self.file_hashes.put(std.heap.page_allocator, owned_path, hash) catch @panic("OOM");
        return hash;
    }

    fn getModuleInfo(
        self: *FileScopeMemo,
        b: *std.Build,
        module: *std.Build.Module,
        module_name: []const u8,
    ) CachedModuleInfo {
        const key = @intFromPtr(module);

        self.mutex.lock();
        if (self.modules.get(key)) |cached| {
            self.mutex.unlock();
            return cached;
        }
        self.mutex.unlock();

        const path = moduleRootSourcePath(b, module, module_name);
        const file_hash = self.getFileHash(path);

        var base_hasher = std.hash.Wyhash.init(0);
        updateHasherWithPathFingerprint(&base_hasher, path, file_hash);
        const base: CachedModuleInfo = .{
            .fingerprint = base_hasher.final(),
        };

        self.mutex.lock();
        if (self.modules.get(key)) |cached| {
            self.mutex.unlock();
            return cached;
        }
        self.modules.put(std.heap.page_allocator, key, base) catch @panic("OOM");
        self.mutex.unlock();

        const computed: CachedModuleInfo = .{
            .fingerprint = self.computeModuleFingerprint(b, module, path, file_hash),
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        self.modules.put(std.heap.page_allocator, key, computed) catch @panic("OOM");
        return computed;
    }

    fn getImportGraphHash(
        self: *FileScopeMemo,
        b: *std.Build,
        roots: []const Import,
    ) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (roots) |dep| {
            const module_info = self.getModuleInfo(b, dep.module, dep.name);
            updateHasherWithNamedFingerprint(&hasher, dep.name, module_info.fingerprint);
        }
        return hasher.final();
    }

    fn computeModuleFingerprint(
        self: *FileScopeMemo,
        b: *std.Build,
        module: *std.Build.Module,
        path: []const u8,
        file_hash: u64,
    ) u64 {
        var hasher = std.hash.Wyhash.init(0);
        updateHasherWithPathFingerprint(&hasher, path, file_hash);
        for (module.import_table.keys(), module.import_table.values()) |child_name, child_module| {
            const child = self.getModuleInfo(b, child_module, child_name);
            updateHasherWithNamedFingerprint(&hasher, child_name, child.fingerprint);
        }
        return hasher.final();
    }
};

var file_scope_memo: FileScopeMemo = .{};

fn optimizeFlag(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "-ODebug",
        .ReleaseSafe => "-OReleaseSafe",
        .ReleaseFast => "-OReleaseFast",
        .ReleaseSmall => "-OReleaseSmall",
    };
}

fn computeBuiltinHostToolKey(
    b: *std.Build,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    imports: []const Import,
) u64 {
    const root_path = root_source_file.getPath(b);
    const root_file_hash = file_scope_memo.getFileHash(root_path);
    const import_graph_hash = file_scope_memo.getImportGraphHash(b, imports);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    updateHasherWithPathFingerprint(&hasher, root_path, root_file_hash);
    updateHasherWithU64(&hasher, import_graph_hash);
    return hasher.final();
}

fn emitToolModuleDefinition(
    b: *std.Build,
    compile: *std.Build.Step.Run,
    emitted: *std.ArrayList(EmittedToolModule),
    name: []const u8,
    module: *std.Build.Module,
) void {
    for (emitted.items) |existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            if (existing.module != module) {
                std.debug.panic("conflicting emitted host tool module mapping for '{s}'", .{name});
            }
            return;
        }
    }

    for (module.import_table.keys(), module.import_table.values()) |child_name, _| {
        compile.addArgs(&.{ "--dep", child_name });
    }
    compile.addPrefixedFileArg(
        b.fmt("-M{s}=", .{name}),
        moduleRootSourceFile(module, name),
    );
    emitted.append(b.allocator, .{
        .name = name,
        .module = module,
    }) catch @panic("OOM");

    for (module.import_table.keys(), module.import_table.values()) |child_name, child_module| {
        emitToolModuleDefinition(b, compile, emitted, child_name, child_module);
    }
}

fn moduleRootSourcePath(
    b: *std.Build,
    module: *std.Build.Module,
    module_name: []const u8,
) []const u8 {
    return moduleRootSourceFile(module, module_name).getPath(b);
}

fn moduleRootSourceFile(module: *std.Build.Module, module_name: []const u8) std.Build.LazyPath {
    return module.root_source_file orelse
        std.debug.panic("module '{s}' must have a root_source_file", .{module_name});
}

fn updateHasherWithPathFingerprint(
    hasher: *std.hash.Wyhash,
    path: []const u8,
    file_hash: u64,
) void {
    hasher.update(path);
    updateHasherWithU64(hasher, file_hash);
}

fn updateHasherWithNamedFingerprint(
    hasher: *std.hash.Wyhash,
    name: []const u8,
    fingerprint: u64,
) void {
    hasher.update(name);
    updateHasherWithU64(hasher, fingerprint);
}

fn updateHasherWithU64(hasher: *std.hash.Wyhash, value: u64) void {
    var little_endian = std.mem.nativeToLittle(u64, value);
    hasher.update(std.mem.asBytes(&little_endian));
}

fn computeFileHash(path: []const u8) u64 {
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch
            std.debug.panic("failed to open host tool input '{s}'", .{path})
    else
        std.fs.cwd().openFile(path, .{}) catch
            std.debug.panic("failed to open host tool input '{s}'", .{path});
    defer file.close();

    var hasher = std.hash.Wyhash.init(0);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch
            std.debug.panic("failed to read host tool input '{s}'", .{path});
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.final();
}
