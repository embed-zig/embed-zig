// Host tool that merges all flashable images for one build into a single raw
// flash image.
// Outputs one combined binary that includes the ESP-IDF flash arguments plus
// any generated extra data partition images.
const std = @import("std");
const build_config = @import("build_config");
const data_partitions = @import("data_partitions.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 6) {
        std.debug.print(
            "usage: combine_flash_image <app_root> <build_dir> <esp_idf> <python_exe> <output>\n",
            .{},
        );
        return error.InvalidArgs;
    }

    _ = args[1];
    const build_dir = args[2];
    _ = args[3];
    const python_executable_path = args[4];
    const output_path = args[5];

    const flash_args_path = try std.fs.path.join(allocator, &.{ build_dir, "idf", "flash_args" });
    const flash_size = try readFlashSizeAlloc(allocator, flash_args_path);
    const images = try data_partitions.resolveDataPartitionImagesAlloc(allocator, build_dir);
    defer data_partitions.freeDataPartitionImages(allocator, images);

    try ensureParentDir(output_path);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.appendSlice(&.{ python_executable_path, "-m", "esptool" });

    try argv.appendSlice(&.{
        "--chip",
        build_config.chip,
        "merge_bin",
        "-o",
        output_path,
        "-f",
        "raw",
    });

    if (flash_size.len != 0) {
        try argv.appendSlice(&.{ "--fill-flash-size", flash_size });
    }

    try appendExpandedFlashArgs(allocator, &argv, flash_args_path);

    for (images) |image| {
        const offset_arg = try std.fmt.allocPrint(allocator, "0x{x}", .{image.offset});
        try argv.append(offset_arg);
        try argv.append(image.output_bin);
    }

    try runCommand(allocator, argv.items, ".");
}

fn readFlashSizeAlloc(allocator: std.mem.Allocator, flash_args_path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(flash_args_path, .{});
    defer file.close();

    const contents = try readFileAlloc(allocator, file);
    var tokens = std.mem.tokenizeAny(u8, contents, " \r\n\t");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "--flash_size")) {
            return allocator.dupe(u8, tokens.next() orelse return error.InvalidArgs);
        }
    }
    return allocator.dupe(u8, "");
}

fn appendExpandedFlashArgs(
    allocator: std.mem.Allocator,
    argv: *std.array_list.Managed([]const u8),
    flash_args_path: []const u8,
) !void {
    const file = try std.fs.cwd().openFile(flash_args_path, .{});
    defer file.close();

    const contents = try readFileAlloc(allocator, file);
    const flash_args_dir = std.fs.path.dirname(flash_args_path) orelse ".";
    var tokens = std.mem.tokenizeAny(u8, contents, " \r\n\t");
    while (tokens.next()) |token| {
        if (token.len > 2 and token[0] == '0' and (token[1] == 'x' or token[1] == 'X')) {
            try argv.append(token);
            const image_path = tokens.next() orelse return error.InvalidArgs;
            const resolved_path = try std.fs.path.join(allocator, &.{ flash_args_dir, image_path });
            try argv.append(resolved_path);
            continue;
        }
        try argv.append(token);
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    const stat = try file.stat();
    const file_size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (file_size == std.math.maxInt(usize)) return error.FileTooBig;
    return try file.readToEndAlloc(allocator, file_size + 1);
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

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_name| {
        try std.fs.cwd().makePath(dir_name);
    }
}
