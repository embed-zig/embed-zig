const Request = @import("Request.zig");
const status = @import("status.zig");

pub const RouteKind = enum {
    exact,
    subtree,
    catch_all,
};

pub fn requestPath(req: *const Request) []const u8 {
    return if (req.url.path.len != 0) req.url.path else "/";
}

pub fn classifyPattern(pattern: []const u8) ?RouteKind {
    if (pattern.len == 0 or pattern[0] != '/') return null;
    if (pattern.len == 1) return .catch_all;
    if (pattern[pattern.len - 1] == '/') return .subtree;
    return .exact;
}

pub fn redirectTo(comptime std: type, rw: anytype, location: []const u8) void {
    _ = std;
    rw.setHeader("Location", location) catch return;
    rw.writeHeader(status.moved_permanently) catch return;
}

pub fn notFound(comptime std: type, rw: anytype) void {
    _ = std;
    rw.writeHeader(status.not_found) catch {};
}

pub fn appendSlash(allocator: anytype, path: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, path.len + 1);
    @memcpy(out[0..path.len], path);
    out[path.len] = '/';
    return out;
}

pub fn cleanPath(comptime std: type, allocator: anytype, path: []const u8) ![]u8 {
    const absolute = path.len == 0 or path[0] == '/';
    const preserve_trailing_slash = path.len > 1 and path[path.len - 1] == '/';

    var segments = std.ArrayList([]const u8){};
    defer segments.deinit(allocator);

    var i: usize = 0;
    while (i <= path.len) {
        const next_slash = std.mem.indexOfScalarPos(u8, path, i, '/') orelse path.len;
        const segment = path[i..next_slash];
        if (segment.len != 0 and !std.mem.eql(u8, segment, ".")) {
            if (std.mem.eql(u8, segment, "..")) {
                if (segments.items.len != 0) _ = segments.pop();
            } else {
                try segments.append(allocator, segment);
            }
        }
        if (next_slash == path.len) break;
        i = next_slash + 1;
    }

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    if (absolute) try out.append(allocator, '/');
    for (segments.items, 0..) |segment, idx| {
        if (idx != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }
    if (preserve_trailing_slash and (out.items.len == 0 or out.items[out.items.len - 1] != '/')) {
        try out.append(allocator, '/');
    }
    if (out.items.len == 0 and absolute) try out.append(allocator, '/');
    return out.toOwnedSlice(allocator);
}

pub const SegmentIter = struct {
    path: []const u8,
    next_index: usize,

    pub fn init(path: []const u8) SegmentIter {
        return .{
            .path = path,
            .next_index = if (path.len != 0 and path[0] == '/') 1 else 0,
        };
    }

    pub fn next(self: *SegmentIter) ?[]const u8 {
        if (self.next_index >= self.path.len) return null;

        const trailing_subtree_marker = self.path.len > 1 and self.path[self.path.len - 1] == '/';
        if (trailing_subtree_marker and self.next_index == self.path.len - 1) return null;

        const start = self.next_index;
        var i = start;
        while (i < self.path.len and self.path[i] != '/') : (i += 1) {}

        if (trailing_subtree_marker and i == self.path.len - 1) {
            self.next_index = self.path.len;
        } else {
            self.next_index = if (i < self.path.len) i + 1 else self.path.len;
        }
        return self.path[start..i];
    }
};
