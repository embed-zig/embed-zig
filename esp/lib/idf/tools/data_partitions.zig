// Host tool that materializes or flashes the non-app partitions from
// `build_config.partition_table`.
// In `build` mode it outputs partition image files in the build directory; in
// `flash` mode it writes those generated images to the target device.
const std = @import("std");
const build_config = @import("build_config");
const idf = @import("esp_idf");
const PartitionTable = idf.PartitionTable;

pub const DataPartitionImage = struct {
    name: []const u8,
    offset: u32,
    output_bin: []const u8,
    data: PartitionTable.DataSource,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 6 or args.len > 7) {
        std.debug.print(
            "usage: data_partitions <build|flash> <app_root> <build_dir> <esp_idf> <python_exe> [port]\n",
            .{},
        );
        return error.InvalidArgs;
    }

    const mode = args[1];
    const app_root = args[2];
    const build_dir = args[3];
    const idf_root = args[4];
    const python_executable_path = args[5];
    const port = if (args.len == 7) args[6] else "";

    if (std.mem.eql(u8, mode, "build")) {
        try buildDataPartitionImages(allocator, app_root, build_dir, idf_root, python_executable_path);
        return;
    }
    if (std.mem.eql(u8, mode, "flash")) {
        try flashBuiltDataPartitionImages(allocator, app_root, build_dir, idf_root, python_executable_path, port);
        return;
    }
    return error.InvalidArgs;
}

pub fn resolveDataPartitionImagesAlloc(
    allocator: std.mem.Allocator,
    build_dir: []const u8,
) ![]DataPartitionImage {
    const table = build_config.partition_table;
    try PartitionTable.validateEntries(table.entries);
    const resolved_entries = try PartitionTable.resolveEntriesAlloc(allocator, table);
    defer allocator.free(resolved_entries);

    var images = std.array_list.Managed(DataPartitionImage).init(allocator);
    errdefer {
        for (images.items) |image| allocator.free(image.output_bin);
        images.deinit();
    }

    for (resolved_entries) |entry| {
        const maybe_data = entry.data orelse continue;
        const output_name = try std.fmt.allocPrint(allocator, "{s}.bin", .{entry.name});
        defer allocator.free(output_name);
        const output_bin = try std.fs.path.join(allocator, &.{ build_dir, output_name });
        try images.append(.{
            .name = entry.name,
            .offset = entry.offset,
            .output_bin = output_bin,
            .data = maybe_data,
        });
    }

    return images.toOwnedSlice();
}

pub fn freeDataPartitionImages(allocator: std.mem.Allocator, images: []const DataPartitionImage) void {
    for (images) |image| {
        allocator.free(image.output_bin);
    }
    allocator.free(images);
}

pub fn buildDataPartitionImages(
    allocator: std.mem.Allocator,
    app_root: []const u8,
    build_dir: []const u8,
    idf_root: []const u8,
    python_executable_path: []const u8,
) !void {
    const images = try resolveDataPartitionImagesAlloc(allocator, build_dir);
    defer freeDataPartitionImages(allocator, images);

    try std.fs.cwd().makePath(build_dir);
    for (images) |image| {
        try buildDataPartitionImage(allocator, app_root, build_dir, idf_root, python_executable_path, image);
    }
}

pub fn flashBuiltDataPartitionImages(
    allocator: std.mem.Allocator,
    _: []const u8,
    build_dir: []const u8,
    idf_root: []const u8,
    python_executable_path: []const u8,
    port: []const u8,
) !void {
    const images = try resolveDataPartitionImagesAlloc(allocator, build_dir);
    defer freeDataPartitionImages(allocator, images);

    for (images) |image| {
        try flashBuiltDataPartitionImage(allocator, idf_root, python_executable_path, port, image);
    }
}

fn buildDataPartitionImage(
    allocator: std.mem.Allocator,
    _: []const u8,
    build_dir: []const u8,
    idf_root: []const u8,
    python_executable_path: []const u8,
    image: DataPartitionImage,
) !void {
    switch (image.data) {
        .spiffs => |cfg| {
            const source_dir = try std.fs.path.join(allocator, &.{cfg.dir});
            defer allocator.free(source_dir);
            const spiffsgen_path = try std.fs.path.join(allocator, &.{ idf_root, "components", "spiffs", "spiffsgen.py" });
            defer allocator.free(spiffsgen_path);
            const size = partitionSizeForName(build_config.partition_table, image.name) orelse
                return error.InvalidArgs;
            const size_arg = try std.fmt.allocPrint(allocator, "0x{x}", .{size});
            defer allocator.free(size_arg);
            try ensureParentDir(image.output_bin);
            try runCommand(allocator, &.{
                python_executable_path,
                spiffsgen_path,
                size_arg,
                source_dir,
                image.output_bin,
                "--page-size",
                "256",
                "--block-size",
                "4096",
            }, ".");
        },
        .littlefs => return error.LittlefsNotImplemented,
        .raw_file => |path| {
            const source_path = try std.fs.path.join(allocator, &.{path});
            defer allocator.free(source_path);
            try ensureParentDir(image.output_bin);
            try copyFile(source_path, image.output_bin);
        },
        .nvs => |cfg| {
            const csv_name = try std.fmt.allocPrint(allocator, "{s}.csv", .{image.name});
            defer allocator.free(csv_name);
            const csv_path = try std.fs.path.join(allocator, &.{ build_dir, csv_name });
            defer allocator.free(csv_path);
            const csv = try PartitionTable.nvsCsvAlloc(allocator, cfg.entries);
            defer allocator.free(csv);
            try writeFileRelative(csv_path, csv);
            const size = partitionSizeForName(build_config.partition_table, image.name) orelse
                return error.InvalidArgs;
            const size_arg = try std.fmt.allocPrint(allocator, "{d}", .{size});
            defer allocator.free(size_arg);
            try ensureParentDir(image.output_bin);
            try runCommand(allocator, &.{
                python_executable_path,
                "-m",
                "esp_idf_nvs_partition_gen",
                "generate",
                csv_path,
                image.output_bin,
                size_arg,
            }, ".");
        },
    }
}

fn flashBuiltDataPartitionImage(
    allocator: std.mem.Allocator,
    _: []const u8,
    python_executable_path: []const u8,
    port: []const u8,
    image: DataPartitionImage,
) !void {
    var flash_args = std.array_list.Managed([]const u8).init(allocator);
    defer flash_args.deinit();
    try flash_args.appendSlice(&.{
        python_executable_path,
        "-m",
        "esptool",
    });
    if (port.len != 0) {
        try flash_args.appendSlice(&.{ "--port", port });
    }
    const offset_arg = try std.fmt.allocPrint(allocator, "0x{x}", .{image.offset});
    defer allocator.free(offset_arg);
    try flash_args.appendSlice(&.{
        "write_flash",
        offset_arg,
        image.output_bin,
    });
    try runCommand(allocator, flash_args.items, ".");
}

fn runCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
) !void {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn copyFile(source_path: []const u8, dest_path: []const u8) !void {
    try ensureParentDir(dest_path);
    const source = if (std.fs.path.isAbsolute(source_path))
        try std.fs.openFileAbsolute(source_path, .{})
    else
        try std.fs.cwd().openFile(source_path, .{});
    defer source.close();

    const dest = if (std.fs.path.isAbsolute(dest_path))
        try std.fs.createFileAbsolute(dest_path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(dest_path, .{ .truncate = true });
    defer dest.close();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try source.read(&buf);
        if (n == 0) break;
        try dest.writeAll(buf[0..n]);
    }
}

fn writeFileRelative(path: []const u8, data: []const u8) !void {
    try ensureParentDir(path);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_name| {
        try std.fs.cwd().makePath(dir_name);
    }
}

fn partitionSizeForName(table: PartitionTable, name: []const u8) ?u32 {
    for (table.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.size;
    }
    return null;
}
