const stdz = @import("stdz");
const JsonParser = @import("JsonParser.zig");
const StatePath = @This();

path: []const u8,
labels: []const []const u8,

pub fn parseSlice(comptime source: []const u8) StatePath {
    comptime {
        @setEvalBranchQuota(20_000);
    }

    var parser = JsonParser.init(source);
    const parsed = parseFromParser(&parser);
    parser.finish();
    return parsed;
}

pub fn parseAllocSlice(
    allocator: stdz.mem.Allocator,
    source: []const u8,
) !StatePath {
    var parsed_value = try stdz.json.parseFromSlice(
        stdz.json.Value,
        allocator,
        source,
        .{},
    );
    defer parsed_value.deinit();

    return try parseJsonValue(allocator, parsed_value.value);
}

pub fn deinit(self: *StatePath, allocator: stdz.mem.Allocator) void {
    allocator.free(self.path);
    for (self.labels) |label| {
        allocator.free(label);
    }
    allocator.free(self.labels);
}

fn parseFromParser(parser: *JsonParser) StatePath {
    parser.expectByte('{');

    var path: ?[]const u8 = null;
    var labels: ?[]const []const u8 = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.StatePath.parseSlice requires `path` and `labels` fields");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "path")) {
            if (path != null) {
                @compileError("zux.spec.StatePath.parseSlice duplicate `path` field");
            }
            path = parser.parseString();
            validatePathComptime(path.?);
        } else if (comptimeEql(key, "labels")) {
            if (labels != null) {
                @compileError("zux.spec.StatePath.parseSlice duplicate `labels` field");
            }
            labels = parseLabelSlices(parser.parseValueSlice());
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.StatePath.parseSlice only supports `path` and `labels` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    return .{
        .path = path orelse @compileError("zux.spec.StatePath.parseSlice requires a `path` field"),
        .labels = labels orelse @compileError("zux.spec.StatePath.parseSlice requires a `labels` field"),
    };
}

fn parseLabelSlices(comptime source: []const u8) []const []const u8 {
    var parser = JsonParser.init(source);
    const labels = comptime blk: {
        const label_count = parser.countArrayItems();
        parser.expectByte('[');

        var next: [label_count][]const u8 = undefined;
        if (!parser.consumeByte(']')) {
            var index: usize = 0;
            while (true) {
                const label = parser.parseString();
                if (label.len == 0) {
                    @compileError("zux.spec.StatePath.parseSlice label must not be empty");
                }
                next[index] = label;
                index += 1;

                if (parser.consumeByte(',')) continue;
                parser.expectByte(']');
                break;
            }
        }
        parser.finish();
        break :blk next;
    };
    return labels[0..];
}

pub fn parseJsonValue(
    allocator: stdz.mem.Allocator,
    value: stdz.json.Value,
) !StatePath {
    if (@inComptime()) {
        const object = switch (value) {
            .object => |object| object,
            else => @compileError("zux.spec.StatePath.parseJsonValue expects a JSON object"),
        };

        const path_value = object.get("path") orelse
            @compileError("zux.spec.StatePath.parseJsonValue requires a `path` field");
        const labels_value = object.get("labels") orelse
            @compileError("zux.spec.StatePath.parseJsonValue requires a `labels` field");

        const path = switch (path_value) {
            .string => |text| blk: {
                validatePathComptime(text);
                break :blk text;
            },
            else => @compileError("zux.spec.StatePath.parseJsonValue `path` must be a JSON string"),
        };
        const labels = parseLabelsValueComptime(labels_value);

        return .{
            .path = path,
            .labels = labels,
        };
    }

    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedStatePathObject,
    };

    const path_value = object.get("path") orelse return error.MissingStatePathPath;
    const labels_value = object.get("labels") orelse return error.MissingStatePathLabels;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stdz.mem.eql(u8, entry.key_ptr.*, "path") and
            !stdz.mem.eql(u8, entry.key_ptr.*, "labels"))
        {
            return error.UnknownStatePathField;
        }
    }

    const path = switch (path_value) {
        .string => |text| blk: {
            try validatePath(text);
            break :blk try allocator.dupe(u8, text);
        },
        else => return error.ExpectedStatePathPathString,
    };
    errdefer allocator.free(path);
    const labels = try parseLabelsValue(allocator, labels_value);
    errdefer {
        for (labels) |label| allocator.free(label);
        allocator.free(labels);
    }

    return .{
        .path = path,
        .labels = labels,
    };
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyStatePathPath;
    if (path[0] == '/' or path[path.len - 1] == '/') return error.InvalidStatePathBoundary;

    var segment_start: usize = 0;
    for (path, 0..) |ch, idx| {
        if (ch == '.') return error.DotSeparatedStatePath;
        if (ch == '/') {
            if (idx == segment_start) return error.EmptyStatePathSegment;
            segment_start = idx + 1;
        }
    }
    if (segment_start == path.len) return error.EmptyStatePathSegment;
}

fn validatePathComptime(comptime path: []const u8) void {
    if (path.len == 0) @compileError("zux.spec.StatePath.parseJsonValue `path` must not be empty");
    if (path[0] == '/' or path[path.len - 1] == '/') {
        @compileError("zux.spec.StatePath.parseJsonValue `path` must not start or end with '/'");
    }

    comptime var segment_start: usize = 0;
    inline for (path, 0..) |ch, idx| {
        if (ch == '.') {
            @compileError("zux.spec.StatePath.parseJsonValue `path` must use '/' separators instead of '.'");
        }
        if (ch == '/') {
            if (idx == segment_start) {
                @compileError("zux.spec.StatePath.parseJsonValue `path` must not contain empty path segments");
            }
            segment_start = idx + 1;
        }
    }
    if (segment_start == path.len) {
        @compileError("zux.spec.StatePath.parseJsonValue `path` must not contain empty path segments");
    }
}

fn parseLabelsValue(
    allocator: stdz.mem.Allocator,
    value: stdz.json.Value,
) ![]const []const u8 {
    const array = switch (value) {
        .array => |array| array,
        else => return error.ExpectedStatePathLabelsArray,
    };

    const labels = try allocator.alloc([]const u8, array.items.len);
    errdefer allocator.free(labels);
    for (array.items, 0..) |item, i| {
        labels[i] = switch (item) {
            .string => |text| blk: {
                if (text.len == 0) return error.EmptyStatePathLabel;
                break :blk try allocator.dupe(u8, text);
            },
            else => return error.ExpectedStatePathLabelString,
        };
        errdefer for (labels[0 .. i + 1]) |label| allocator.free(label);
    }

    return labels;
}

fn parseLabelsValueComptime(comptime value: stdz.json.Value) []const []const u8 {
    const array = switch (value) {
        .array => |array| array,
        else => @compileError("zux.spec.StatePath.parseJsonValue `labels` must be a JSON array"),
    };

    var labels: [array.items.len][]const u8 = undefined;
    inline for (array.items, 0..) |item, i| {
        labels[i] = switch (item) {
            .string => |text| blk: {
                if (text.len == 0) @compileError("zux.spec.StatePath.parseJsonValue label must not be empty");
                break :blk text;
            },
            else => @compileError("zux.spec.StatePath.parseJsonValue labels must be JSON strings"),
        };
    }

    return labels[0..];
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}
