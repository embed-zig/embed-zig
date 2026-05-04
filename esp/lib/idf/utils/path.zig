const std = @import("std");

pub fn relativePathWithinRoot(root: []const u8, path: []const u8) []const u8 {
    const prefix = if (std.mem.eql(u8, root, ".")) "" else root;
    if (prefix.len == 0) return path;

    if (std.mem.eql(u8, path, prefix)) return ".";

    if (path.len > prefix.len and std.mem.startsWith(u8, path, prefix)) {
        const next = path[prefix.len];
        if (next == '/' or next == '\\') return path[prefix.len + 1 ..];
    }

    std.debug.panic(
        "path '{s}' is not contained under root '{s}'",
        .{ path, root },
    );
}

pub fn joinRelativePath(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var filtered = std.ArrayList([]const u8).empty;
    defer filtered.deinit(allocator);

    for (parts) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        try filtered.append(allocator, part);
    }

    if (filtered.items.len == 0) {
        return allocator.dupe(u8, ".");
    }
    if (filtered.items.len == 1) {
        return allocator.dupe(u8, filtered.items[0]);
    }
    return std.fs.path.join(allocator, filtered.items);
}

pub fn isValidRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;

    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

test "relativePathWithinRoot handles root exact and nested paths" {
    try std.testing.expectEqualStrings("wifi.c", relativePathWithinRoot(".", "wifi.c"));
    try std.testing.expectEqualStrings(".", relativePathWithinRoot("esp_main_helper", "esp_main_helper"));
    try std.testing.expectEqualStrings(
        "include/wifi.h",
        relativePathWithinRoot("esp_main_helper", "esp_main_helper/include/wifi.h"),
    );
}

test "joinRelativePath filters empty and dot segments" {
    const allocator = std.testing.allocator;

    const joined_root = try joinRelativePath(allocator, &.{ "", "." });
    defer allocator.free(joined_root);
    try std.testing.expectEqualStrings(".", joined_root);

    const joined_single = try joinRelativePath(allocator, &.{ ".", "wifi.c" });
    defer allocator.free(joined_single);
    try std.testing.expectEqualStrings("wifi.c", joined_single);

    const joined_nested = try joinRelativePath(allocator, &.{ ".", "include", "wifi.h" });
    defer allocator.free(joined_nested);
    const expected = try std.fs.path.join(allocator, &.{ "include", "wifi.h" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, joined_nested);
}

test "isValidRelativePath rejects absolute and parent paths" {
    try std.testing.expect(isValidRelativePath("wifi_helper.c"));
    try std.testing.expect(isValidRelativePath("src/wifi_helper.c"));
    try std.testing.expect(!isValidRelativePath(""));
    try std.testing.expect(!isValidRelativePath("../wifi_helper.c"));
}
