// Host tool that recreates the staged `idf_project` directory used by `addApp`.
// Outputs the generated project CMake files and component wrappers that let
// ESP-IDF build Zig-produced artifacts alongside source components.
const std = @import("std");
const esp_idf = @import("esp_idf");
const build_config = @import("build_config");
const fs_utils = esp_idf.fs_utils;
const path_utils = esp_idf.path_utils;

comptime {
    _ = build_config.chip;
    _ = build_config.sdk_config;
}

const ArchiveComponent = struct {
    name: []const u8,
    archive_file_name: []const u8,
};

const SourceComponentFile = struct {
    idf_project_path: []const u8,
    original_path: []const u8,
};

const SourceComponentIncludeDir = struct {
    idf_project_path: []const u8,
    original_path: []const u8,
};

const SourceComponent = struct {
    name: []const u8,
    srcs: []SourceComponentFile,
    copy_files: []SourceComponentFile,
    archives: []SourceComponentFile,
    include_dirs: []SourceComponentIncludeDir,
    requires: []const []const u8,
    priv_requires: []const []const u8,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print(
            "usage: {s} <project_dir> <project_name> --entry-component <name> [--archive <component=archive.a>] [--source-component ...]\n",
            .{args[0]},
        );
        return error.InvalidArguments;
    }

    const project_dir = args[1];
    const project_name = args[2];
    const parsed = try parseComponentArgs(allocator, args[3..]);
    defer allocator.free(parsed.entry_component_name);
    defer freeArchiveComponents(allocator, parsed.archives);
    defer freeSourceComponents(allocator, parsed.sources);

    try recreateGeneratedProject(project_dir);
    try writeRootCmake(allocator, project_dir, project_name);
    try writeMainComponent(allocator, project_dir, parsed.entry_component_name);

    for (parsed.archives) |component| {
        try writeArchiveComponent(allocator, project_dir, component);
    }
    for (parsed.sources) |component| {
        try writeSourceComponent(allocator, project_dir, component);
    }
}

const ParsedComponents = struct {
    entry_component_name: []const u8,
    archives: []ArchiveComponent,
    sources: []SourceComponent,
};

fn parseComponentArgs(
    allocator: std.mem.Allocator,
    specs: []const []const u8,
) !ParsedComponents {
    var entry_component_name: ?[]const u8 = null;
    errdefer if (entry_component_name) |name| allocator.free(name);
    var archives = std.ArrayList(ArchiveComponent).empty;
    errdefer {
        for (archives.items) |component| {
            allocator.free(component.name);
            allocator.free(component.archive_file_name);
        }
        archives.deinit(allocator);
    }
    var sources = std.ArrayList(SourceComponent).empty;
    errdefer {
        for (sources.items) |component| {
            allocator.free(component.name);
            for (component.srcs) |src| {
                allocator.free(src.idf_project_path);
                allocator.free(src.original_path);
            }
            allocator.free(component.srcs);
            for (component.copy_files) |copy_file| {
                allocator.free(copy_file.idf_project_path);
                allocator.free(copy_file.original_path);
            }
            allocator.free(component.copy_files);
            for (component.archives) |archive| {
                allocator.free(archive.idf_project_path);
                allocator.free(archive.original_path);
            }
            allocator.free(component.archives);
            for (component.include_dirs) |include_dir| {
                allocator.free(include_dir.idf_project_path);
                allocator.free(include_dir.original_path);
            }
            allocator.free(component.include_dirs);
            for (component.requires) |require_name| allocator.free(require_name);
            allocator.free(component.requires);
            for (component.priv_requires) |require_name| allocator.free(require_name);
            allocator.free(component.priv_requires);
        }
        sources.deinit(allocator);
    }

    var idx: usize = 0;
    while (idx < specs.len) {
        const tag = specs[idx];
        idx += 1;

        if (std.mem.eql(u8, tag, "--entry-component")) {
            if (idx >= specs.len) return error.InvalidArguments;
            if (entry_component_name != null) return error.InvalidArguments;
            entry_component_name = try allocator.dupe(u8, specs[idx]);
            idx += 1;
            continue;
        }

        if (std.mem.eql(u8, tag, "--archive")) {
            if (idx >= specs.len) return error.InvalidArguments;
            try archives.append(allocator, try parseArchiveComponent(allocator, specs[idx]));
            idx += 1;
            continue;
        }

        if (std.mem.eql(u8, tag, "--source-component")) {
            const parsed, const next_idx = try parseSourceComponent(allocator, specs, idx);
            try sources.append(allocator, parsed);
            idx = next_idx;
            continue;
        }

        return error.InvalidArguments;
    }

    const resolved_entry_component_name = entry_component_name orelse return error.InvalidArguments;
    return .{
        .entry_component_name = resolved_entry_component_name,
        .archives = try archives.toOwnedSlice(allocator),
        .sources = try sources.toOwnedSlice(allocator),
    };
}

fn parseArchiveComponent(
    allocator: std.mem.Allocator,
    spec: []const u8,
) !ArchiveComponent {
    const eq_idx = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidArguments;
    const raw_name = std.mem.trim(u8, spec[0..eq_idx], " \t\r\n");
    const raw_file_name = std.mem.trim(u8, spec[eq_idx + 1 ..], " \t\r\n");
    if (raw_name.len == 0 or raw_file_name.len == 0) {
        return error.InvalidArguments;
    }
    return .{
        .name = try allocator.dupe(u8, raw_name),
        .archive_file_name = try allocator.dupe(u8, raw_file_name),
    };
}

fn freeArchiveComponents(allocator: std.mem.Allocator, components: []ArchiveComponent) void {
    for (components) |component| {
        allocator.free(component.name);
        allocator.free(component.archive_file_name);
    }
    allocator.free(components);
}

fn parseSourceComponent(
    allocator: std.mem.Allocator,
    specs: []const []const u8,
    start_idx: usize,
) !struct { SourceComponent, usize } {
    var idx = start_idx;
    if (idx + 6 >= specs.len) return error.InvalidArguments;

    const name = try allocator.dupe(u8, specs[idx]);
    errdefer allocator.free(name);
    idx += 1;

    const src_count = try std.fmt.parseUnsigned(usize, specs[idx], 10);
    idx += 1;
    const copy_file_count = try std.fmt.parseUnsigned(usize, specs[idx], 10);
    idx += 1;
    const archive_count = try std.fmt.parseUnsigned(usize, specs[idx], 10);
    idx += 1;
    const include_dir_count = try std.fmt.parseUnsigned(usize, specs[idx], 10);
    idx += 1;
    const require_count = try std.fmt.parseUnsigned(usize, specs[idx], 10);
    idx += 1;
    const priv_require_count = try std.fmt.parseUnsigned(usize, specs[idx], 10);
    idx += 1;

    if (idx + src_count * 2 + copy_file_count * 2 + archive_count * 2 + include_dir_count * 2 + require_count + priv_require_count > specs.len) {
        return error.InvalidArguments;
    }

    const srcs = try allocator.alloc(SourceComponentFile, src_count);
    errdefer allocator.free(srcs);
    for (srcs) |*src| src.* = .{ .idf_project_path = "", .original_path = "" };
    errdefer {
        for (srcs) |src| {
            if (src.idf_project_path.len != 0) allocator.free(src.idf_project_path);
            if (src.original_path.len != 0) allocator.free(src.original_path);
        }
    }
    for (srcs) |*src| {
        src.* = .{
            .idf_project_path = try allocator.dupe(u8, specs[idx]),
            .original_path = try allocator.dupe(u8, specs[idx + 1]),
        };
        idx += 2;
    }

    const copy_files = try allocator.alloc(SourceComponentFile, copy_file_count);
    errdefer allocator.free(copy_files);
    for (copy_files) |*copy_file| copy_file.* = .{ .idf_project_path = "", .original_path = "" };
    errdefer {
        for (copy_files) |copy_file| {
            if (copy_file.idf_project_path.len != 0) allocator.free(copy_file.idf_project_path);
            if (copy_file.original_path.len != 0) allocator.free(copy_file.original_path);
        }
    }
    for (copy_files) |*copy_file| {
        copy_file.* = .{
            .idf_project_path = try allocator.dupe(u8, specs[idx]),
            .original_path = try allocator.dupe(u8, specs[idx + 1]),
        };
        idx += 2;
    }

    const archives = try allocator.alloc(SourceComponentFile, archive_count);
    errdefer allocator.free(archives);
    for (archives) |*archive| archive.* = .{ .idf_project_path = "", .original_path = "" };
    errdefer {
        for (archives) |archive| {
            if (archive.idf_project_path.len != 0) allocator.free(archive.idf_project_path);
            if (archive.original_path.len != 0) allocator.free(archive.original_path);
        }
    }
    for (archives) |*archive| {
        archive.* = .{
            .idf_project_path = try allocator.dupe(u8, specs[idx]),
            .original_path = try allocator.dupe(u8, specs[idx + 1]),
        };
        idx += 2;
    }

    const include_dirs = try allocator.alloc(SourceComponentIncludeDir, include_dir_count);
    errdefer allocator.free(include_dirs);
    for (include_dirs) |*include_dir| include_dir.* = .{ .idf_project_path = "", .original_path = "" };
    errdefer {
        for (include_dirs) |include_dir| {
            if (include_dir.idf_project_path.len != 0) allocator.free(include_dir.idf_project_path);
            if (include_dir.original_path.len != 0) allocator.free(include_dir.original_path);
        }
    }
    for (include_dirs) |*include_dir| {
        include_dir.* = .{
            .idf_project_path = try allocator.dupe(u8, specs[idx]),
            .original_path = try allocator.dupe(u8, specs[idx + 1]),
        };
        idx += 2;
    }

    const requires = try allocator.alloc([]const u8, require_count);
    errdefer {
        for (requires) |require_name| {
            if (require_name.len != 0) allocator.free(require_name);
        }
        allocator.free(requires);
    }
    for (requires) |*require_name| require_name.* = "";
    for (requires, 0..) |*require_name, require_idx| {
        require_name.* = try allocator.dupe(u8, specs[idx + require_idx]);
    }
    idx += require_count;

    const priv_requires = try allocator.alloc([]const u8, priv_require_count);
    errdefer {
        for (priv_requires) |require_name| {
            if (require_name.len != 0) allocator.free(require_name);
        }
        allocator.free(priv_requires);
    }
    for (priv_requires) |*require_name| require_name.* = "";
    for (priv_requires, 0..) |*require_name, require_idx| {
        require_name.* = try allocator.dupe(u8, specs[idx + require_idx]);
    }
    idx += priv_require_count;

    return .{
        .{
            .name = name,
            .srcs = srcs,
            .copy_files = copy_files,
            .archives = archives,
            .include_dirs = include_dirs,
            .requires = requires,
            .priv_requires = priv_requires,
        },
        idx,
    };
}

fn freeSourceComponents(allocator: std.mem.Allocator, components: []SourceComponent) void {
    for (components) |component| {
        allocator.free(component.name);
        for (component.srcs) |src| {
            allocator.free(src.idf_project_path);
            allocator.free(src.original_path);
        }
        allocator.free(component.srcs);
        for (component.copy_files) |copy_file| {
            allocator.free(copy_file.idf_project_path);
            allocator.free(copy_file.original_path);
        }
        allocator.free(component.copy_files);
        for (component.archives) |archive| {
            allocator.free(archive.idf_project_path);
            allocator.free(archive.original_path);
        }
        allocator.free(component.archives);
        for (component.include_dirs) |include_dir| {
            allocator.free(include_dir.idf_project_path);
            allocator.free(include_dir.original_path);
        }
        allocator.free(component.include_dirs);
        for (component.requires) |require_name| allocator.free(require_name);
        allocator.free(component.requires);
        for (component.priv_requires) |require_name| allocator.free(require_name);
        allocator.free(component.priv_requires);
    }
    allocator.free(components);
}

fn recreateGeneratedProject(project_dir: []const u8) !void {
    if (std.fs.cwd().access(project_dir, .{})) |_| {
        try std.fs.cwd().deleteTree(project_dir);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (std.fs.path.dirname(project_dir)) |build_dir| {
        const idf_build_dir = try std.fs.path.join(std.heap.page_allocator, &.{ build_dir, "idf" });
        defer std.heap.page_allocator.free(idf_build_dir);
        if (std.fs.cwd().access(idf_build_dir, .{})) |_| {
            try std.fs.cwd().deleteTree(idf_build_dir);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    try std.fs.cwd().makePath(project_dir);
    var project = try std.fs.cwd().openDir(project_dir, .{});
    defer project.close();
    try project.makePath("main");
    try project.makePath("components");
}

fn writeRootCmake(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    project_name: []const u8,
) !void {
    const root_path = try std.fs.path.join(allocator, &.{ project_dir, "CMakeLists.txt" });
    defer allocator.free(root_path);

    const content = try std.fmt.allocPrint(
        allocator,
        "cmake_minimum_required(VERSION 3.16)\n\n" ++
            "include($ENV{{IDF_PATH}}/tools/cmake/project.cmake)\n" ++
            "project({s})\n",
        .{project_name},
    );
    defer allocator.free(content);

    try std.fs.cwd().writeFile(.{
        .sub_path = root_path,
        .data = content,
    });
}

fn writeMainComponent(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    entry_component_name: []const u8,
) !void {
    const main_cmake_path = try std.fs.path.join(allocator, &.{ project_dir, "main", "CMakeLists.txt" });
    defer allocator.free(main_cmake_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    try writer.writeAll(
        "idf_component_register(\n" ++
            "    SRCS\n" ++
            "        \"app_main.generated.c\"\n" ++
            "    INCLUDE_DIRS\n" ++
            "        \".\"\n",
    );

    try writer.writeAll("    REQUIRES\n");
    try writer.print("        {s}\n", .{entry_component_name});
    try writer.writeAll(")\n");

    try std.fs.cwd().writeFile(.{
        .sub_path = main_cmake_path,
        .data = out.items,
    });
}

fn writeArchiveComponent(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    component: ArchiveComponent,
) !void {
    const component_dir = try std.fs.path.join(
        allocator,
        &.{ project_dir, "components", component.name },
    );
    defer allocator.free(component_dir);
    try std.fs.cwd().makePath(component_dir);

    const dummy_c_path = try std.fs.path.join(allocator, &.{ component_dir, "dummy.c" });
    defer allocator.free(dummy_c_path);
    const dummy_content = try std.fmt.allocPrint(
        allocator,
        "void espz_component_dummy_{s}(void) {{}}\n",
        .{component.name},
    );
    defer allocator.free(dummy_content);
    try std.fs.cwd().writeFile(.{
        .sub_path = dummy_c_path,
        .data = dummy_content,
    });

    const cmake_path = try std.fs.path.join(allocator, &.{ component_dir, "CMakeLists.txt" });
    defer allocator.free(cmake_path);
    var cmake_content = std.ArrayList(u8).empty;
    defer cmake_content.deinit(allocator);
    const writer = cmake_content.writer(allocator);

    try writer.writeAll(
        "idf_component_register(\n" ++
            "    SRCS\n" ++
            "        \"dummy.c\"\n" ++
            "    INCLUDE_DIRS\n" ++
            "        \".\"\n",
    );
    try writer.writeAll(")\n\n");
    try writer.print(
        "add_prebuilt_library({s}_archive \"${{CMAKE_CURRENT_LIST_DIR}}/{s}\")\n",
        .{ component.name, component.archive_file_name },
    );
    try writer.print(
        "target_link_libraries(${{COMPONENT_LIB}} INTERFACE {s}_archive)\n",
        .{component.name},
    );
    try std.fs.cwd().writeFile(.{
        .sub_path = cmake_path,
        .data = cmake_content.items,
    });
}

fn writeSourceComponent(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    component: SourceComponent,
) !void {
    const component_dir = try std.fs.path.join(
        allocator,
        &.{ project_dir, "components", component.name },
    );
    defer allocator.free(component_dir);
    try std.fs.cwd().makePath(component_dir);

    for (component.srcs) |src| {
        const destination_path = try std.fs.path.join(
            allocator,
            &.{ project_dir, src.idf_project_path },
        );
        defer allocator.free(destination_path);
        if (std.fs.path.dirname(destination_path)) |parent_dir| {
            try std.fs.cwd().makePath(parent_dir);
        }
        try fs_utils.copyFileAbsoluteOrRelative(src.original_path, destination_path);
    }

    for (component.copy_files) |copy_file| {
        const destination_path = try std.fs.path.join(
            allocator,
            &.{ project_dir, copy_file.idf_project_path },
        );
        defer allocator.free(destination_path);
        if (std.fs.path.dirname(destination_path)) |parent_dir| {
            try std.fs.cwd().makePath(parent_dir);
        }
        try fs_utils.copyFileAbsoluteOrRelative(copy_file.original_path, destination_path);
    }

    for (component.archives) |archive| {
        const destination_path = try std.fs.path.join(
            allocator,
            &.{ project_dir, archive.idf_project_path },
        );
        defer allocator.free(destination_path);
        if (std.fs.path.dirname(destination_path)) |parent_dir| {
            try std.fs.cwd().makePath(parent_dir);
        }
        try fs_utils.copyFileAbsoluteOrRelative(archive.original_path, destination_path);
    }

    for (component.include_dirs) |include_dir| {
        try fs_utils.copyDirectoryAbsoluteOrRelative(
            allocator,
            include_dir.original_path,
            project_dir,
            include_dir.idf_project_path,
        );
    }

    const has_cmake_sources = blk: {
        for (component.srcs) |src| {
            const local_path = try componentLocalPath(allocator, component.name, src.idf_project_path);
            defer allocator.free(local_path);
            if (!isObjectFile(local_path)) break :blk true;
        }
        break :blk false;
    };

    if (!has_cmake_sources) {
        const dummy_c_path = try std.fs.path.join(allocator, &.{ component_dir, "dummy.c" });
        defer allocator.free(dummy_c_path);
        const dummy_content = try std.fmt.allocPrint(
            allocator,
            "void espz_component_dummy_{s}(void) {{}}\n",
            .{component.name},
        );
        defer allocator.free(dummy_content);
        try std.fs.cwd().writeFile(.{
            .sub_path = dummy_c_path,
            .data = dummy_content,
        });
    }

    const cmake_path = try std.fs.path.join(allocator, &.{ component_dir, "CMakeLists.txt" });
    defer allocator.free(cmake_path);

    var cmake_content = std.ArrayList(u8).empty;
    defer cmake_content.deinit(allocator);
    const writer = cmake_content.writer(allocator);

    try writer.writeAll(
        "idf_component_register(\n" ++
            "    SRCS\n",
    );
    if (has_cmake_sources) {
        for (component.srcs) |src| {
            const local_path = try componentLocalPath(allocator, component.name, src.idf_project_path);
            defer allocator.free(local_path);
            if (isObjectFile(local_path)) continue;
            try writer.print("        \"{s}\"\n", .{local_path});
        }
    } else {
        try writer.writeAll("        \"dummy.c\"\n");
    }
    try writer.writeAll(
        "    INCLUDE_DIRS\n" ++
            "        \".\"\n",
    );
    for (component.include_dirs) |include_dir| {
        const local_path = try componentLocalPath(allocator, component.name, include_dir.idf_project_path);
        defer allocator.free(local_path);
        if (std.mem.eql(u8, local_path, ".")) continue;
        try writer.print("        \"{s}\"\n", .{local_path});
    }
    if (component.requires.len != 0) {
        try writer.writeAll("    REQUIRES\n");
        for (component.requires) |require_name| {
            try writer.print("        {s}\n", .{require_name});
        }
    }
    if (component.priv_requires.len != 0) {
        try writer.writeAll("    PRIV_REQUIRES\n");
        for (component.priv_requires) |require_name| {
            try writer.print("        {s}\n", .{require_name});
        }
    }
    try writer.writeAll(")\n");

    for (component.archives, 0..) |archive, archive_idx| {
        const local_path = try componentLocalPath(allocator, component.name, archive.idf_project_path);
        defer allocator.free(local_path);
        try writer.print(
            "\nadd_prebuilt_library({s}_archive_{d} \"${{CMAKE_CURRENT_LIST_DIR}}/{s}\")\n",
            .{ component.name, archive_idx, local_path },
        );
        try writer.print(
            "target_link_libraries(${{COMPONENT_LIB}} INTERFACE {s}_archive_{d})\n",
            .{ component.name, archive_idx },
        );
    }

    for (component.srcs) |src| {
        const local_path = try componentLocalPath(allocator, component.name, src.idf_project_path);
        defer allocator.free(local_path);
        if (!isObjectFile(local_path)) continue;
        try writer.print(
            "\nset_source_files_properties(\"${{CMAKE_CURRENT_LIST_DIR}}/{s}\" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)\n",
            .{local_path},
        );
        try writer.print(
            "target_sources(${{COMPONENT_LIB}} PRIVATE \"${{CMAKE_CURRENT_LIST_DIR}}/{s}\")\n",
            .{local_path},
        );
    }

    try std.fs.cwd().writeFile(.{
        .sub_path = cmake_path,
        .data = cmake_content.items,
    });
}

fn isObjectFile(relative_path: []const u8) bool {
    return std.mem.endsWith(u8, relative_path, ".o") or std.mem.endsWith(u8, relative_path, ".obj");
}

fn componentLocalPath(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    idf_project_path: []const u8,
) ![]const u8 {
    const component_root = try path_utils.joinRelativePath(allocator, &.{ "components", component_name });
    defer allocator.free(component_root);
    return allocator.dupe(u8, path_utils.relativePathWithinRoot(component_root, idf_project_path));
}
