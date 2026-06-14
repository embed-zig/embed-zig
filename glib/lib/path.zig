const std = @import("std");

pub fn isAbs(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

pub fn trimTrailingSlash(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    return path[0..end];
}

pub fn baseName(path: []const u8) []const u8 {
    const trimmed = trimTrailingSlash(path);
    if (trimmed.len == 0) return "";
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |index| {
        return trimmed[index + 1 ..];
    }
    return trimmed;
}

pub fn dirName(path: []const u8) []const u8 {
    const trimmed = trimTrailingSlash(path);
    if (trimmed.len == 0) return ".";
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |index| {
        if (index == 0) return "/";
        return trimTrailingSlash(trimmed[0..index]);
    }
    return ".";
}

pub fn extName(path: []const u8) []const u8 {
    const base = baseName(path);
    if (base.len == 0 or base[0] == '.') return "";
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |index| {
        if (index == 0) return "";
        return base[index..];
    }
    return "";
}

pub fn join(buf: []u8, first: []const u8, second: []const u8) ![]const u8 {
    if (first.len == 0) return std.fmt.bufPrint(buf, "{s}", .{second});
    if (second.len == 0) return std.fmt.bufPrint(buf, "{s}", .{trimTrailingSlash(first)});

    const left = trimTrailingSlash(first);
    var right = second;
    while (right.len > 0 and right[0] == '/') : (right = right[1..]) {}
    if (left.len == 0) return std.fmt.bufPrint(buf, "{s}", .{right});
    if (std.mem.eql(u8, left, "/")) return std.fmt.bufPrint(buf, "/{s}", .{right});
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ left, right });
}

pub const test_runner = struct {
    pub const unit = @import("path/test_runner/unit.zig");
};
