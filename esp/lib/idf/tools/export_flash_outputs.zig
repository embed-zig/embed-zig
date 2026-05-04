// Host tool that collects the flashable outputs from a completed app build.
// Outputs copies of the ESP-IDF image files, generated data partition images,
// and the app ELF into the requested `out` directory.
const std = @import("std");
const data_partitions = @import("data_partitions.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 4) {
        std.debug.print(
            "usage: export_flash_outputs <build_dir> <out_dir> <app_name>\n",
            .{},
        );
        return error.InvalidArgs;
    }

    const build_dir = args[1];
    const out_dir = args[2];
    const app_name = args[3];
    try std.fs.cwd().makePath(out_dir);

    const flash_args_path = try std.fs.path.join(allocator, &.{ build_dir, "idf", "flash_args" });
    try exportIdfFlashImages(allocator, flash_args_path, out_dir);

    const partition_images = try data_partitions.resolveDataPartitionImagesAlloc(allocator, build_dir);
    defer data_partitions.freeDataPartitionImages(allocator, partition_images);

    for (partition_images) |image| {
        const dest_path = try std.fs.path.join(allocator, &.{ out_dir, std.fs.path.basename(image.output_bin) });
        defer allocator.free(dest_path);
        try copyFile(image.output_bin, dest_path);
    }

    const app_elf_name = try std.fmt.allocPrint(allocator, "{s}.elf", .{app_name});
    defer allocator.free(app_elf_name);
    const app_elf_path = try std.fs.path.join(allocator, &.{ build_dir, "idf", app_elf_name });
    defer allocator.free(app_elf_path);
    const out_elf_path = try std.fs.path.join(allocator, &.{ out_dir, app_elf_name });
    defer allocator.free(out_elf_path);
    try copyFile(app_elf_path, out_elf_path);
}

fn exportIdfFlashImages(
    allocator: std.mem.Allocator,
    flash_args_path: []const u8,
    out_dir: []const u8,
) !void {
    const file = try std.fs.cwd().openFile(flash_args_path, .{});
    defer file.close();

    const contents = try readFileAlloc(allocator, file);
    const flash_args_dir = std.fs.path.dirname(flash_args_path) orelse ".";
    var tokens = std.mem.tokenizeAny(u8, contents, " \r\n\t");
    while (tokens.next()) |token| {
        if (token.len > 2 and token[0] == '0' and (token[1] == 'x' or token[1] == 'X')) {
            const image_path = tokens.next() orelse return error.InvalidArgs;
            const resolved_path = try std.fs.path.join(allocator, &.{ flash_args_dir, image_path });
            defer allocator.free(resolved_path);
            const dest_path = try std.fs.path.join(allocator, &.{ out_dir, std.fs.path.basename(image_path) });
            defer allocator.free(dest_path);
            try copyFile(resolved_path, dest_path);
        }
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    const stat = try file.stat();
    const file_size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (file_size == std.math.maxInt(usize)) return error.FileTooBig;
    return try file.readToEndAlloc(allocator, file_size + 1);
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

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_name| {
        try std.fs.cwd().makePath(dir_name);
    }
}
