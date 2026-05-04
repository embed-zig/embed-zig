const std = @import("std");

pub fn makePathAbsoluteOrRelative(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        return std.fs.cwd().makePath(path);
    }

    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    var dir = try std.fs.openDirAbsolute(dirname, .{});
    defer dir.close();
    try dir.makePath(std.fs.path.basename(path));
}

pub fn writeFileAbsoluteOrRelative(path: []const u8, data: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        try std.fs.cwd().writeFile(.{
            .sub_path = path,
            .data = data,
        });
        return;
    }

    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    var dir = try std.fs.openDirAbsolute(dirname, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = std.fs.path.basename(path),
        .data = data,
    });
}

pub fn openFileAbsoluteOrRelative(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

pub fn createFileAbsoluteOrRelative(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
        var dir = try std.fs.openDirAbsolute(dirname, .{});
        defer dir.close();
        return dir.createFile(std.fs.path.basename(path), .{ .truncate = true });
    }
    return std.fs.cwd().createFile(path, .{ .truncate = true });
}

pub fn openDirAbsoluteOrRelative(path: []const u8, options: std.fs.Dir.OpenOptions) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openDirAbsolute(path, options);
    }
    return std.fs.cwd().openDir(path, options);
}

pub fn copyFileAbsoluteOrRelative(source_path: []const u8, destination_path: []const u8) !void {
    if (std.fs.path.dirname(destination_path)) |dir_path| {
        try makePathAbsoluteOrRelative(dir_path);
    }

    const source_file = try openFileAbsoluteOrRelative(source_path);
    defer source_file.close();

    const destination_file = try createFileAbsoluteOrRelative(destination_path);
    defer destination_file.close();

    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const bytes_read = try source_file.read(&buffer);
        if (bytes_read == 0) break;
        try destination_file.writeAll(buffer[0..bytes_read]);
    }
}

pub fn copyDirectoryAbsoluteOrRelative(
    allocator: std.mem.Allocator,
    source_dir_path: []const u8,
    component_dir: []const u8,
    relative_path: []const u8,
) !void {
    const destination_dir = if (std.mem.eql(u8, relative_path, "."))
        try allocator.dupe(u8, component_dir)
    else
        try std.fs.path.join(allocator, &.{ component_dir, relative_path });
    defer allocator.free(destination_dir);
    try makePathAbsoluteOrRelative(destination_dir);

    var source_dir = try openDirAbsoluteOrRelative(source_dir_path, .{ .iterate = true });
    defer source_dir.close();

    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (shouldSkipCopiedPath(entry.path)) continue;

        const source_entry_path = try std.fs.path.join(allocator, &.{ source_dir_path, entry.path });
        defer allocator.free(source_entry_path);
        const destination_path = try std.fs.path.join(allocator, &.{ destination_dir, entry.path });
        defer allocator.free(destination_path);

        switch (entry.kind) {
            .directory => try makePathAbsoluteOrRelative(destination_path),
            .file => try copyFileAbsoluteOrRelative(source_entry_path, destination_path),
            else => {},
        }
    }
}

fn shouldSkipCopiedPath(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".zig-cache")) return true;
        if (std.mem.eql(u8, segment, "zig-out")) return true;
        if (std.mem.eql(u8, segment, ".git")) return true;
    }
    return false;
}

fn tmpRootRelative(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "copyFileAbsoluteOrRelative supports relative source and absolute destination" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{
        .sub_path = "src/file.txt",
        .data = "hello from fs util\n",
    });

    const root_rel = try tmpRootRelative(allocator, &tmp);
    defer allocator.free(root_rel);
    const root_abs = try std.fs.realpathAlloc(allocator, root_rel);
    defer allocator.free(root_abs);

    const source_rel = try std.fs.path.join(allocator, &.{ root_rel, "src", "file.txt" });
    defer allocator.free(source_rel);
    const destination_abs = try std.fs.path.join(allocator, &.{ root_abs, "out", "file.txt" });
    defer allocator.free(destination_abs);

    try copyFileAbsoluteOrRelative(source_rel, destination_abs);

    const content = try tmp.dir.readFileAlloc(allocator, "out/file.txt", 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello from fs util\n", content);
}

test "copyFileAbsoluteOrRelative supports files larger than 1 MiB" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const large_size = 2 * 1024 * 1024;
    const large_data = try allocator.alloc(u8, large_size);
    defer allocator.free(large_data);
    @memset(large_data, 0xab);

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{
        .sub_path = "src/large.bin",
        .data = large_data,
    });

    const root_rel = try tmpRootRelative(allocator, &tmp);
    defer allocator.free(root_rel);
    const root_abs = try std.fs.realpathAlloc(allocator, root_rel);
    defer allocator.free(root_abs);

    const source_abs = try std.fs.path.join(allocator, &.{ root_abs, "src", "large.bin" });
    defer allocator.free(source_abs);
    const destination_abs = try std.fs.path.join(allocator, &.{ root_abs, "out", "large.bin" });
    defer allocator.free(destination_abs);

    try copyFileAbsoluteOrRelative(source_abs, destination_abs);

    const copied = try tmp.dir.readFileAlloc(allocator, "out/large.bin", large_size + 1);
    defer allocator.free(copied);
    try std.testing.expectEqual(large_size, copied.len);
    try std.testing.expectEqualSlices(u8, large_data, copied);
}

test "copyDirectoryAbsoluteOrRelative copies nested directory trees" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/include/nested");
    try tmp.dir.writeFile(.{
        .sub_path = "src/include/wifi.h",
        .data = "#pragma once\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "src/include/nested/detail.h",
        .data = "#define DETAIL 1\n",
    });

    const root_rel = try tmpRootRelative(allocator, &tmp);
    defer allocator.free(root_rel);
    const root_abs = try std.fs.realpathAlloc(allocator, root_rel);
    defer allocator.free(root_abs);

    const source_abs = try std.fs.path.join(allocator, &.{ root_abs, "src", "include" });
    defer allocator.free(source_abs);
    const component_rel = try std.fs.path.join(allocator, &.{ root_rel, "out", "esp_main_helper" });
    defer allocator.free(component_rel);

    try copyDirectoryAbsoluteOrRelative(allocator, source_abs, component_rel, "include");

    const header = try tmp.dir.readFileAlloc(allocator, "out/esp_main_helper/include/wifi.h", 1024);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("#pragma once\n", header);

    const nested = try tmp.dir.readFileAlloc(allocator, "out/esp_main_helper/include/nested/detail.h", 1024);
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("#define DETAIL 1\n", nested);
}

test "copyDirectoryAbsoluteOrRelative skips build cache directories" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/include/.zig-cache/o");
    try tmp.dir.writeFile(.{
        .sub_path = "src/include/header.h",
        .data = "#pragma once\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "src/include/.zig-cache/o/huge.bin",
        .data = "ignore me\n",
    });

    const root_rel = try tmpRootRelative(allocator, &tmp);
    defer allocator.free(root_rel);
    const root_abs = try std.fs.realpathAlloc(allocator, root_rel);
    defer allocator.free(root_abs);

    const source_abs = try std.fs.path.join(allocator, &.{ root_abs, "src", "include" });
    defer allocator.free(source_abs);
    const component_rel = try std.fs.path.join(allocator, &.{ root_rel, "out", "esp_main_helper" });
    defer allocator.free(component_rel);

    try copyDirectoryAbsoluteOrRelative(allocator, source_abs, component_rel, "include");

    const header = try tmp.dir.readFileAlloc(allocator, "out/esp_main_helper/include/header.h", 1024);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("#pragma once\n", header);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access("out/esp_main_helper/include/.zig-cache/o/huge.bin", .{}),
    );
}
