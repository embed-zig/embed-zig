const std = @import("std");
const ExtractedFile = @import("ExtractedFile.zig");
const fs_utils = @import("utils/fs.zig");
const path_utils = @import("utils/path.zig");

const Module = std.Build.Module;
const LazyPath = std.Build.LazyPath;

const Self = @This();

/// Source-based ESP-IDF component metadata.
///
/// This intentionally feels closer to Zig's `Build.Module` API than to a static
/// manifest: create the component once, then incrementally add sources,
/// include paths, and dependencies.
owner: *std.Build,
name: []const u8,
single_sources: std.ArrayListUnmanaged(Module.CSourceFile) = .empty,
source_batches: std.ArrayListUnmanaged(Module.CSourceFiles) = .empty,
extra_files: std.ArrayListUnmanaged(ExtraFile) = .empty,
artifacts: std.ArrayListUnmanaged(*std.Build.Step.Compile) = .empty,
archive_files: std.ArrayListUnmanaged(ArchiveFile) = .empty,
include_dirs: std.ArrayListUnmanaged(LazyPath) = .empty,
requires: std.ArrayListUnmanaged([]const u8) = .empty,
priv_requires: std.ArrayListUnmanaged([]const u8) = .empty,

pub const CreateOptions = struct {
    name: []const u8,
};

pub const CSourceFile = Module.CSourceFile;
pub const CSourceFiles = Module.CSourceFiles;
pub const AddCSourceFilesOptions = Module.AddCSourceFilesOptions;
pub const ExtraFile = struct {
    relative_path: []const u8,
    file: LazyPath,
};
pub const ArchiveFile = struct {
    relative_path: []const u8,
    file: LazyPath,
};

pub const Extracted = struct {
    name: []const u8,
    srcs: []const File,
    copy_files: []const File,
    archives: []const Archive,
    include_dirs: []const IncludeDir,
    requires: []const []const u8,
    priv_requires: []const []const u8,

    pub const File = ExtractedFile;
    pub const Archive = ExtractedFile;
    pub const IncludeDir = ExtractedFile;
};

pub fn create(b: *std.Build, options: CreateOptions) *Self {
    validateComponentNameOrPanic(options.name, "component name");

    const component = b.allocator.create(Self) catch @panic("OOM");
    component.* = .{
        .owner = b,
        .name = b.dupe(options.name),
    };
    return component;
}

pub fn addCSourceFile(component: *Self, source: CSourceFile) void {
    const b = component.owner;
    component.single_sources.append(b.allocator, source.dupe(b)) catch @panic("OOM");
}

pub fn addCSourceFiles(component: *Self, options: AddCSourceFilesOptions) void {
    const b = component.owner;

    for (options.files) |path| {
        if (!path_utils.isValidRelativePath(path)) {
            std.debug.panic(
                "idf.Component '{s}' requires relative file paths in addCSourceFiles(), found '{s}'",
                .{ component.name, path },
            );
        }
    }

    component.source_batches.append(b.allocator, .{
        .root = (options.root orelse b.path("")).dupe(b),
        .files = b.dupeStrings(options.files),
        .flags = b.dupeStrings(options.flags),
        .language = options.language,
    }) catch @panic("OOM");
}

pub fn addIncludePath(component: *Self, lazy_path: LazyPath) void {
    const b = component.owner;
    component.include_dirs.append(b.allocator, lazy_path.dupe(b)) catch @panic("OOM");
}

pub fn addFile(component: *Self, extra_file: ExtraFile) void {
    if (!path_utils.isValidRelativePath(extra_file.relative_path)) {
        std.debug.panic(
            "idf.Component '{s}' requires a relative extra file path, found '{s}'",
            .{ component.name, extra_file.relative_path },
        );
    }

    component.extra_files.append(component.owner.allocator, .{
        .relative_path = component.owner.dupe(extra_file.relative_path),
        .file = extra_file.file.dupe(component.owner),
    }) catch @panic("OOM");
}

pub fn addArtifact(component: *Self, artifact: *std.Build.Step.Compile) void {
    if (!artifactIsStaticLibrary(artifact) and !artifactIsObject(artifact)) {
        std.debug.panic(
            "idf.Component '{s}' addArtifact() expects a static library or object artifact, found kind={s} linkage={?}",
            .{ component.name, @tagName(artifact.kind), artifact.linkage },
        );
    }

    component.artifacts.append(component.owner.allocator, artifact) catch @panic("OOM");
}

pub fn addArchiveFile(component: *Self, archive: ArchiveFile) void {
    if (!path_utils.isValidRelativePath(archive.relative_path)) {
        std.debug.panic(
            "idf.Component '{s}' requires a relative archive path, found '{s}'",
            .{ component.name, archive.relative_path },
        );
    }
    if (!std.mem.endsWith(u8, archive.relative_path, ".a")) {
        std.debug.panic(
            "idf.Component '{s}' archive path must end with .a, found '{s}'",
            .{ component.name, archive.relative_path },
        );
    }

    component.archive_files.append(component.owner.allocator, .{
        .relative_path = component.owner.dupe(archive.relative_path),
        .file = archive.file.dupe(component.owner),
    }) catch @panic("OOM");
}

pub fn addRequire(component: *Self, name: []const u8) void {
    appendUniqueDependency(&component.requires, component.owner, component.name, "requires", name);
}

pub fn addPrivRequire(component: *Self, name: []const u8) void {
    appendUniqueDependency(&component.priv_requires, component.owner, component.name, "priv_requires", name);
}

pub fn extract(component: *const Self, idf_component_path: []const u8) !Extracted {
    return extractWithPrefix(component, idf_component_path);
}

fn extractWithPrefix(component: *const Self, idf_path_prefix: []const u8) !Extracted {
    component.validate();

    const b = component.owner;
    const component_root_path = try inferComponentRoot(component, b);
    const srcs = try b.allocator.alloc(
        Extracted.File,
        sourceFileCount(component) + objectArtifactCount(component),
    );
    const copy_files = try b.allocator.alloc(Extracted.File, component.extra_files.items.len);
    const archives = try b.allocator.alloc(Extracted.Archive, staticLibraryArtifactCount(component) + component.archive_files.items.len);
    const include_dirs = try b.allocator.alloc(Extracted.IncludeDir, component.include_dirs.items.len);

    var next_src: usize = 0;
    for (component.source_batches.items) |batch| {
        for (batch.files) |file| {
            const original_path = batch.root.path(b, file);
            srcs[next_src] = .{
                .idf_project_path = try prefixedIdfProjectPath(
                    b,
                    idf_path_prefix,
                    component_root_path,
                    original_path.getPath(b),
                    file,
                ),
                .original_path = original_path.dupe(b),
            };
            next_src += 1;
        }
    }

    for (component.single_sources.items) |source| {
        srcs[next_src] = .{
            .idf_project_path = try prefixedIdfProjectPath(
                b,
                idf_path_prefix,
                component_root_path,
                source.file.getPath(b),
                std.fs.path.basename(source.file.getPath(b)),
            ),
            .original_path = source.file.dupe(b),
        };
        next_src += 1;
    }

    var next_copy_file: usize = 0;
    for (component.extra_files.items) |extra_file| {
        copy_files[next_copy_file] = .{
            .idf_project_path = try path_utils.joinRelativePath(
                b.allocator,
                &.{ idf_path_prefix, extra_file.relative_path },
            ),
            .original_path = extra_file.file.dupe(b),
        };
        next_copy_file += 1;
    }

    for (component.artifacts.items) |artifact| {
        if (!artifactIsObject(artifact)) continue;
        srcs[next_src] = .{
            .idf_project_path = try path_utils.joinRelativePath(
                b.allocator,
                &.{ idf_path_prefix, artifact.out_filename },
            ),
            .original_path = artifact.getEmittedBin().dupe(b),
        };
        next_src += 1;
    }

    var next_archive: usize = 0;
    for (component.artifacts.items) |artifact| {
        if (!artifactIsStaticLibrary(artifact)) continue;
        archives[next_archive] = .{
            .idf_project_path = try path_utils.joinRelativePath(
                b.allocator,
                &.{ idf_path_prefix, artifact.out_filename },
            ),
            .original_path = artifact.getEmittedBin().dupe(b),
        };
        next_archive += 1;
    }

    for (component.archive_files.items) |archive| {
        archives[next_archive] = .{
            .idf_project_path = try path_utils.joinRelativePath(
                b.allocator,
                &.{ idf_path_prefix, archive.relative_path },
            ),
            .original_path = archive.file.dupe(b),
        };
        next_archive += 1;
    }

    for (component.include_dirs.items, 0..) |include_dir, include_idx| {
        include_dirs[include_idx] = .{
            .idf_project_path = try prefixedIdfProjectPath(
                b,
                idf_path_prefix,
                component_root_path,
                include_dir.getPath(b),
                std.fs.path.basename(include_dir.getPath(b)),
            ),
            .original_path = include_dir.dupe(b),
        };
    }

    return .{
        .name = b.dupe(component.name),
        .srcs = srcs,
        .copy_files = copy_files,
        .archives = archives,
        .include_dirs = include_dirs,
        .requires = b.dupeStrings(component.requires.items),
        .priv_requires = b.dupeStrings(component.priv_requires.items),
    };
}

pub fn extractTo(component: *const Self, dir_path: []const u8) !void {
    const b = component.owner;
    const extracted = try extractWithPrefix(component, ".");

    try fs_utils.makePathAbsoluteOrRelative(dir_path);

    for (extracted.srcs) |src| {
        const destination_path = try std.fs.path.join(b.allocator, &.{ dir_path, src.idf_project_path });
        defer b.allocator.free(destination_path);
        try fs_utils.copyFileAbsoluteOrRelative(src.original_path.getPath(b), destination_path);
    }

    for (extracted.copy_files) |copy_file| {
        const destination_path = try std.fs.path.join(b.allocator, &.{ dir_path, copy_file.idf_project_path });
        defer b.allocator.free(destination_path);
        try fs_utils.copyFileAbsoluteOrRelative(copy_file.original_path.getPath(b), destination_path);
    }

    for (extracted.archives) |archive| {
        const destination_path = try std.fs.path.join(b.allocator, &.{ dir_path, archive.idf_project_path });
        defer b.allocator.free(destination_path);
        try fs_utils.copyFileAbsoluteOrRelative(archive.original_path.getPath(b), destination_path);
    }

    for (extracted.include_dirs) |include_dir| {
        try fs_utils.copyDirectoryAbsoluteOrRelative(
            b.allocator,
            include_dir.original_path.getPath(b),
            dir_path,
            include_dir.idf_project_path,
        );
    }

    try writeComponentCmakeLists(extracted, dir_path);
}

pub fn validate(component: *const Self) void {
    if (!component.hasContent()) {
        std.debug.panic(
            "idf.Component '{s}' must declare at least one staged file or artifact",
            .{component.name},
        );
    }
}

pub fn hasContent(component: *const Self) bool {
    return component.single_sources.items.len != 0 or
        component.source_batches.items.len != 0 or
        component.extra_files.items.len != 0 or
        component.artifacts.items.len != 0 or
        component.archive_files.items.len != 0;
}

pub fn hasSources(component: *const Self) bool {
    return component.single_sources.items.len != 0 or component.source_batches.items.len != 0;
}

fn appendUniqueDependency(
    list: *std.ArrayListUnmanaged([]const u8),
    b: *std.Build,
    component_name: []const u8,
    field_name: []const u8,
    name: []const u8,
) void {
    validateComponentNameOrPanic(name, field_name);

    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }

    list.append(b.allocator, b.dupe(name)) catch @panic("OOM");
    _ = component_name;
}

fn validateComponentNameOrPanic(name: []const u8, field_label: []const u8) void {
    if (!isValidComponentName(name)) {
        std.debug.panic(
            "idf.Component {s} '{s}' contains unsupported characters",
            .{ field_label, name },
        );
    }
}

fn isValidComponentName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok =
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or
            c == '-';
        if (!ok) return false;
    }
    return true;
}

fn inferComponentRoot(component: *const Self, b: *std.Build) ![]const u8 {
    var roots = std.ArrayList([]const u8).empty;
    defer roots.deinit(b.allocator);

    for (component.source_batches.items) |batch| {
        try roots.append(b.allocator, batch.root.getPath(b));
    }
    for (component.single_sources.items) |source| {
        try roots.append(b.allocator, source.file.dirname().getPath(b));
    }
    for (component.include_dirs.items) |include_dir| {
        try roots.append(b.allocator, include_dir.getPath(b));
    }

    if (roots.items.len == 0) return b.dupe(".");

    var common_root = roots.items[0];
    for (roots.items[1..]) |root_path| {
        common_root = commonAncestorPath(common_root, root_path);
        if (common_root.len == 0) break;
    }

    if (common_root.len == 0) return b.dupe(".");
    return b.dupe(common_root);
}

fn prefixedIdfProjectPath(
    b: *std.Build,
    idf_path_prefix: []const u8,
    component_root_path: []const u8,
    original_path: []const u8,
    fallback_leaf: []const u8,
) ![]const u8 {
    const local_path = if (pathWithinRoot(component_root_path, original_path)) |relative_path|
        try b.allocator.dupe(u8, relative_path)
    else
        try b.allocator.dupe(u8, fallback_leaf);
    defer b.allocator.free(local_path);

    return path_utils.joinRelativePath(b.allocator, &.{ idf_path_prefix, local_path });
}

fn pathWithinRoot(root: []const u8, path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, ".") or root.len == 0) return null;

    if (std.mem.eql(u8, path, root)) return ".";
    if (path.len <= root.len) return null;
    if (!std.mem.startsWith(u8, path, root)) return null;

    const next = path[root.len];
    if (next == '/' or next == '\\') return path[root.len + 1 ..];
    return null;
}

fn commonAncestorPath(a: []const u8, b: []const u8) []const u8 {
    const max_len = @min(a.len, b.len);
    var idx: usize = 0;
    var last_separator: ?usize = null;

    while (idx < max_len and a[idx] == b[idx]) : (idx += 1) {
        if (a[idx] == '/' or a[idx] == '\\') last_separator = idx;
    }

    if (idx == a.len and (idx == b.len or b[idx] == '/' or b[idx] == '\\')) return a;
    if (idx == b.len and (idx == a.len or a[idx] == '/' or a[idx] == '\\')) return b;
    if (last_separator) |separator_idx| {
        if (separator_idx == 0) return "";
        return a[0..separator_idx];
    }
    return "";
}

fn sourceFileCount(component: *const Self) usize {
    var total = component.single_sources.items.len;
    for (component.source_batches.items) |batch| {
        total += batch.files.len;
    }
    return total;
}

fn objectArtifactCount(component: *const Self) usize {
    var total: usize = 0;
    for (component.artifacts.items) |artifact| {
        if (artifactIsObject(artifact)) total += 1;
    }
    return total;
}

fn staticLibraryArtifactCount(component: *const Self) usize {
    var total: usize = 0;
    for (component.artifacts.items) |artifact| {
        if (artifactIsStaticLibrary(artifact)) total += 1;
    }
    return total;
}

fn artifactIsStaticLibrary(artifact: *std.Build.Step.Compile) bool {
    return artifact.kind == .lib and artifact.linkage == .static;
}

fn artifactIsObject(artifact: *std.Build.Step.Compile) bool {
    return artifact.kind == .obj;
}

fn writeComponentCmakeLists(extracted: Extracted, target_dir: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const cmake_path = try std.fs.path.join(allocator, &.{ target_dir, "CMakeLists.txt" });
    defer allocator.free(cmake_path);

    const needs_stub = !hasCmakeSourceFiles(extracted.srcs);
    if (needs_stub) {
        const stub_path = try std.fs.path.join(allocator, &.{ target_dir, "dummy.c" });
        defer allocator.free(stub_path);
        try fs_utils.writeFileAbsoluteOrRelative(stub_path, "void espz_component_dummy(void) {}\n");
    }

    var cmake_content = std.ArrayList(u8).empty;
    defer cmake_content.deinit(allocator);
    const writer = cmake_content.writer(allocator);

    try writer.writeAll(
        "idf_component_register(\n" ++
            "    SRCS\n",
    );
    if (needs_stub) {
        try writer.writeAll("        \"dummy.c\"\n");
    } else {
        for (extracted.srcs) |src| {
            if (isObjectFile(src.idf_project_path)) continue;
            try writer.print("        \"{s}\"\n", .{src.idf_project_path});
        }
    }
    try writer.writeAll(
        "    INCLUDE_DIRS\n" ++
            "        \".\"\n",
    );
    for (extracted.include_dirs) |include_dir| {
        if (std.mem.eql(u8, include_dir.idf_project_path, ".")) continue;
        try writer.print("        \"{s}\"\n", .{include_dir.idf_project_path});
    }
    if (extracted.requires.len != 0) {
        try writer.writeAll("    REQUIRES\n");
        for (extracted.requires) |require_name| {
            try writer.print("        {s}\n", .{require_name});
        }
    }
    if (extracted.priv_requires.len != 0) {
        try writer.writeAll("    PRIV_REQUIRES\n");
        for (extracted.priv_requires) |require_name| {
            try writer.print("        {s}\n", .{require_name});
        }
    }
    try writer.writeAll(")\n");

    for (extracted.archives, 0..) |archive, idx| {
        try writer.print(
            "\nadd_prebuilt_library({s}_archive_{d} \"${{CMAKE_CURRENT_LIST_DIR}}/{s}\")\n",
            .{ extracted.name, idx, archive.idf_project_path },
        );
        try writer.print(
            "target_link_libraries(${{COMPONENT_LIB}} INTERFACE {s}_archive_{d})\n",
            .{ extracted.name, idx },
        );
    }

    for (extracted.srcs) |src| {
        if (!isObjectFile(src.idf_project_path)) continue;
        try writer.print(
            "\nset_source_files_properties(\"${{CMAKE_CURRENT_LIST_DIR}}/{s}\" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)\n",
            .{src.idf_project_path},
        );
        try writer.print(
            "target_sources(${{COMPONENT_LIB}} PRIVATE \"${{CMAKE_CURRENT_LIST_DIR}}/{s}\")\n",
            .{src.idf_project_path},
        );
    }

    try fs_utils.writeFileAbsoluteOrRelative(cmake_path, cmake_content.items);
}

fn hasCmakeSourceFiles(srcs: []const Extracted.File) bool {
    for (srcs) |src| {
        if (!isObjectFile(src.idf_project_path)) return true;
    }
    return false;
}

fn isObjectFile(relative_path: []const u8) bool {
    return std.mem.endsWith(u8, relative_path, ".o") or std.mem.endsWith(u8, relative_path, ".obj");
}

fn createTestBuild(arena: std.mem.Allocator) !*std.Build {
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

    return std.Build.create(
        graph,
        .{ .path = "test", .handle = std.fs.cwd() },
        .{ .path = "test", .handle = std.fs.cwd() },
        &.{},
    );
}

test "isValidComponentName accepts idf-style names" {
    try std.testing.expect(isValidComponentName("wifi_helper"));
    try std.testing.expect(isValidComponentName("esp-wifi"));
    try std.testing.expect(!isValidComponentName(""));
    try std.testing.expect(!isValidComponentName("wifi/helper"));
}

test "extract returns lean component description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const b = try createTestBuild(arena);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("component-src/include");
    try tmp.dir.writeFile(.{
        .sub_path = "component-src/wifi.c",
        .data = "int espz_wifi_helper(void) { return 42; }\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "component-src/include/wifi.h",
        .data = "#pragma once\nint espz_wifi_helper(void);\n",
    });

    const tmp_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const source_root = try std.fs.path.join(arena, &.{ tmp_root, "component-src" });
    const include_root = try std.fs.path.join(arena, &.{ source_root, "include" });
    const archive_sources = b.addWriteFiles();
    const archive_root = archive_sources.add("archive_dep.zig",
        \\export fn archive_value() i32 {
        \\    return 7;
        \\}
        \\
    );
    const archive_artifact = b.addLibrary(.{
        .linkage = .static,
        .name = "archive_dep",
        .root_module = b.createModule(.{
            .root_source_file = archive_root,
            .target = b.graph.host,
        }),
    });

    const component = create(b, .{ .name = "esp_main_helper" });
    component.addCSourceFiles(.{
        .root = .{ .cwd_relative = source_root },
        .files = &.{"wifi.c"},
    });
    component.addIncludePath(.{ .cwd_relative = include_root });
    component.addArtifact(archive_artifact);
    component.addRequire("esp_wifi");
    component.addPrivRequire("nvs_flash");

    const extracted = try component.extract("components/esp_main_helper");
    const expected_source = try std.fs.path.join(arena, &.{ source_root, "wifi.c" });
    try std.testing.expectEqualStrings("esp_main_helper", extracted.name);
    try std.testing.expectEqual(@as(usize, 1), extracted.srcs.len);
    try std.testing.expectEqual(@as(usize, 0), extracted.copy_files.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.archives.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.include_dirs.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.requires.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.priv_requires.len);
    try std.testing.expectEqualStrings("components/esp_main_helper/wifi.c", extracted.srcs[0].idf_project_path);
    try std.testing.expectEqualStrings(expected_source, extracted.srcs[0].original_path.getPath(b));
    try std.testing.expectEqualStrings("components/esp_main_helper/libarchive_dep.a", extracted.archives[0].idf_project_path);
    try std.testing.expect(std.meta.eql(archive_artifact.getEmittedBin().dupe(b), extracted.archives[0].original_path));
    try std.testing.expectEqualStrings("components/esp_main_helper/include", extracted.include_dirs[0].idf_project_path);
    try std.testing.expectEqualStrings(include_root, extracted.include_dirs[0].original_path.getPath(b));
    try std.testing.expectEqualStrings("esp_wifi", extracted.requires[0]);
    try std.testing.expectEqualStrings("nvs_flash", extracted.priv_requires[0]);
}

test "extractTo writes sources includes and CMakeLists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const b = try createTestBuild(arena);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("component-src/include");
    try tmp.dir.writeFile(.{
        .sub_path = "component-src/wifi.c",
        .data = "int espz_wifi_helper(void) { return 42; }\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "component-src/include/wifi.h",
        .data = "#pragma once\nint espz_wifi_helper(void);\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "component-src/idf_component.yml",
        .data = "dependencies:\n  espressif/led_strip: \"^2.4.1\"\n",
    });

    const tmp_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const source_root = try std.fs.path.join(arena, &.{ tmp_root, "component-src" });
    const include_root = try std.fs.path.join(arena, &.{ source_root, "include" });
    const extra_file_path = try std.fs.path.join(arena, &.{ source_root, "idf_component.yml" });
    const output_root = try std.fs.path.join(arena, &.{ tmp_root, "out", "esp_main_helper" });

    const component = create(b, .{ .name = "esp_main_helper" });
    component.addCSourceFiles(.{
        .root = .{ .cwd_relative = source_root },
        .files = &.{"wifi.c"},
    });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = .{ .cwd_relative = extra_file_path },
    });
    component.addIncludePath(.{ .cwd_relative = include_root });
    component.addRequire("esp_wifi");
    component.addPrivRequire("nvs_flash");

    try component.extractTo(output_root);

    const staged_source = try tmp.dir.readFileAlloc(std.testing.allocator, "out/esp_main_helper/wifi.c", 1024);
    defer std.testing.allocator.free(staged_source);
    try std.testing.expectEqualStrings("int espz_wifi_helper(void) { return 42; }\n", staged_source);

    const staged_header = try tmp.dir.readFileAlloc(std.testing.allocator, "out/esp_main_helper/include/wifi.h", 1024);
    defer std.testing.allocator.free(staged_header);
    try std.testing.expectEqualStrings("#pragma once\nint espz_wifi_helper(void);\n", staged_header);

    const staged_manifest = try tmp.dir.readFileAlloc(std.testing.allocator, "out/esp_main_helper/idf_component.yml", 1024);
    defer std.testing.allocator.free(staged_manifest);
    try std.testing.expectEqualStrings("dependencies:\n  espressif/led_strip: \"^2.4.1\"\n", staged_manifest);

    const staged_cmake = try tmp.dir.readFileAlloc(std.testing.allocator, "out/esp_main_helper/CMakeLists.txt", 4096);
    defer std.testing.allocator.free(staged_cmake);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "idf_component_register(") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "\"wifi.c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "idf_component.yml") == null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "\"include\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "esp_wifi") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "nvs_flash") != null);
}

test "extractTo stages file only components with a dummy source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const b = try createTestBuild(arena);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("component-src");
    try tmp.dir.writeFile(.{
        .sub_path = "component-src/idf_component.yml",
        .data = "dependencies:\n  espressif/led_strip: \"^2.4.1\"\n",
    });

    const tmp_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const component_root = try std.fs.path.join(arena, &.{ tmp_root, "component-src" });
    const extra_file_path = try std.fs.path.join(arena, &.{ component_root, "idf_component.yml" });
    const output_root = try std.fs.path.join(arena, &.{ tmp_root, "out", "manifest_only" });

    const component = create(b, .{ .name = "manifest_only" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = .{ .cwd_relative = extra_file_path },
    });

    const extracted = try component.extract("components/manifest_only");
    try std.testing.expectEqual(@as(usize, 0), extracted.srcs.len);
    try std.testing.expectEqual(@as(usize, 1), extracted.copy_files.len);
    try std.testing.expectEqualStrings(
        "components/manifest_only/idf_component.yml",
        extracted.copy_files[0].idf_project_path,
    );

    try component.extractTo(output_root);

    const staged_manifest = try tmp.dir.readFileAlloc(std.testing.allocator, "out/manifest_only/idf_component.yml", 1024);
    defer std.testing.allocator.free(staged_manifest);
    try std.testing.expectEqualStrings("dependencies:\n  espressif/led_strip: \"^2.4.1\"\n", staged_manifest);

    const staged_cmake = try tmp.dir.readFileAlloc(std.testing.allocator, "out/manifest_only/CMakeLists.txt", 4096);
    defer std.testing.allocator.free(staged_cmake);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "\"dummy.c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "idf_component.yml") == null);
}

test "writeComponentCmakeLists writes external object artifacts into component CMakeLists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const b = try createTestBuild(arena);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const output_root = try std.fs.path.join(arena, &.{ tmp_root, "out", "zig_entry" });
    const object_sources = b.addWriteFiles();
    const entry_root = object_sources.add("entry.zig",
        \\export fn zig_esp_main() void {}
        \\
    );
    const entry_object = b.addObject(.{
        .name = "zig_entry",
        .root_module = b.createModule(.{
            .root_source_file = entry_root,
            .target = b.graph.host,
        }),
    });

    const component = create(b, .{ .name = "zig_entry" });
    component.addArtifact(entry_object);
    component.addRequire("grt");

    const extracted = try component.extract(".");
    try fs_utils.makePathAbsoluteOrRelative(output_root);
    try writeComponentCmakeLists(extracted, output_root);

    const staged_cmake = try tmp.dir.readFileAlloc(std.testing.allocator, "out/zig_entry/CMakeLists.txt", 4096);
    defer std.testing.allocator.free(staged_cmake);

    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "dummy.c") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "EXTERNAL_OBJECT TRUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "target_sources(${COMPONENT_LIB} PRIVATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, entry_object.out_filename) != null);
    try std.testing.expect(std.mem.indexOf(u8, staged_cmake, "grt") != null);
}

test "extract keeps multiple source roots under their shared ancestor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const b = try createTestBuild(arena);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("lib/grt/time");
    try tmp.dir.makePath("lib/grt/std/thread");
    try tmp.dir.writeFile(.{
        .sub_path = "lib/grt/time/binding.c",
        .data = "void grt_time_binding(void) {}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "lib/grt/std/thread/binding.c",
        .data = "void grt_thread_binding(void) {}\n",
    });

    const tmp_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const time_root = try std.fs.path.join(arena, &.{ tmp_root, "lib", "grt", "time" });
    const thread_root = try std.fs.path.join(arena, &.{ tmp_root, "lib", "grt", "std", "thread" });

    const component = create(b, .{ .name = "grt" });
    component.addCSourceFiles(.{
        .root = .{ .cwd_relative = time_root },
        .files = &.{"binding.c"},
    });
    component.addCSourceFiles(.{
        .root = .{ .cwd_relative = thread_root },
        .files = &.{"binding.c"},
    });
    component.addIncludePath(.{ .cwd_relative = time_root });
    component.addIncludePath(.{ .cwd_relative = thread_root });

    const extracted = try component.extract("components/grt");

    try std.testing.expectEqual(@as(usize, 2), extracted.srcs.len);
    try std.testing.expectEqual(@as(usize, 0), extracted.copy_files.len);
    try std.testing.expectEqual(@as(usize, 2), extracted.include_dirs.len);
    try std.testing.expectEqualStrings(
        "components/grt/time/binding.c",
        extracted.srcs[0].idf_project_path,
    );
    try std.testing.expectEqualStrings(
        "components/grt/std/thread/binding.c",
        extracted.srcs[1].idf_project_path,
    );
    try std.testing.expectEqualStrings(
        "components/grt/time",
        extracted.include_dirs[0].idf_project_path,
    );
    try std.testing.expectEqualStrings(
        "components/grt/std/thread",
        extracted.include_dirs[1].idf_project_path,
    );
}
