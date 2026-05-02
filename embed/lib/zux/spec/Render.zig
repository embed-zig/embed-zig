const glib = @import("glib");
const JsonParser = @import("JsonParser.zig");
const Render = @This();

label: []const u8,
state_path: []const u8,
render_fn_name: []const u8,

pub fn parseSlice(comptime source: []const u8) Render {
    comptime {
        @setEvalBranchQuota(20_000);
    }

    var parser = JsonParser.init(source);
    const parsed = parseFromParser(&parser);
    parser.finish();
    return parsed;
}

pub fn parseAllocSlice(
    allocator: glib.std.mem.Allocator,
    source: []const u8,
) !Render {
    var parsed_value = try glib.std.json.parseFromSlice(
        glib.std.json.Value,
        allocator,
        source,
        .{},
    );
    defer parsed_value.deinit();

    return try parseJsonValue(allocator, parsed_value.value);
}

pub fn deinit(self: *Render, allocator: glib.std.mem.Allocator) void {
    allocator.free(self.label);
    allocator.free(self.state_path);
    allocator.free(self.render_fn_name);
}

fn parseFromParser(parser: *JsonParser) Render {
    parser.expectByte('{');

    var label: ?[]const u8 = null;
    var state_path: ?[]const u8 = null;
    var render_fn_name: ?[]const u8 = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.Render.parseSlice requires `label`, `state_path`, and `fn_name` fields");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "label")) {
            if (label != null) {
                @compileError("zux.spec.Render.parseSlice duplicate `label` field");
            }
            label = parser.parseString();
            if (label.?.len == 0) {
                @compileError("zux.spec.Render.parseSlice `label` must not be empty");
            }
        } else if (comptimeEql(key, "state_path") or comptimeEql(key, "path")) {
            if (state_path != null) {
                @compileError("zux.spec.Render.parseSlice duplicate state path field");
            }
            state_path = parser.parseString();
            validateStatePathComptime(state_path.?);
        } else if (comptimeEql(key, "fn_name")) {
            if (render_fn_name != null) {
                @compileError("zux.spec.Render.parseSlice duplicate render function field");
            }
            render_fn_name = parser.parseString();
            if (render_fn_name.?.len == 0) {
                @compileError("zux.spec.Render.parseSlice `fn_name` must not be empty");
            }
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.Render.parseSlice only supports `label`, `state_path`, `path`, and `fn_name` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    return .{
        .label = label orelse @compileError("zux.spec.Render.parseSlice requires a `label` field"),
        .state_path = state_path orelse @compileError("zux.spec.Render.parseSlice requires a `state_path` or `path` field"),
        .render_fn_name = render_fn_name orelse @compileError("zux.spec.Render.parseSlice requires a `fn_name` field"),
    };
}

pub fn parseJsonValue(
    allocator: glib.std.mem.Allocator,
    value: glib.std.json.Value,
) !Render {
    if (@inComptime()) {
        const object = switch (value) {
            .object => |object| object,
            else => @compileError("zux.spec.Render.parseJsonValue expects a JSON object"),
        };

        const label_value = object.get("label") orelse
            @compileError("zux.spec.Render.parseJsonValue requires a `label` field");
        const state_path_value = object.get("state_path") orelse
            object.get("path") orelse
            @compileError("zux.spec.Render.parseJsonValue requires a `state_path` or `path` field");
        const render_fn_name_value = object.get("fn_name") orelse
            @compileError("zux.spec.Render.parseJsonValue requires a `fn_name` field");

        const label = switch (label_value) {
            .string => |text| blk: {
                if (text.len == 0) @compileError("zux.spec.Render.parseJsonValue `label` must not be empty");
                break :blk text;
            },
            else => @compileError("zux.spec.Render.parseJsonValue `label` must be a JSON string"),
        };
        const state_path = switch (state_path_value) {
            .string => |text| blk: {
                validateStatePathComptime(text);
                break :blk text;
            },
            else => @compileError("zux.spec.Render.parseJsonValue `state_path` must be a JSON string"),
        };
        const render_fn_name = switch (render_fn_name_value) {
            .string => |text| blk: {
                if (text.len == 0) @compileError("zux.spec.Render.parseJsonValue `fn_name` must not be empty");
                break :blk text;
            },
            else => @compileError("zux.spec.Render.parseJsonValue `fn_name` must be a JSON string"),
        };

        return .{
            .label = label,
            .state_path = state_path,
            .render_fn_name = render_fn_name,
        };
    }

    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedRenderObject,
    };

    const label_value = object.get("label") orelse return error.MissingRenderLabel;
    const state_path_value = object.get("state_path") orelse
        object.get("path") orelse
        return error.MissingRenderStatePath;
    const render_fn_name_value = object.get("fn_name") orelse
        return error.MissingRenderFnName;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!glib.std.mem.eql(u8, entry.key_ptr.*, "label") and
            !glib.std.mem.eql(u8, entry.key_ptr.*, "state_path") and
            !glib.std.mem.eql(u8, entry.key_ptr.*, "path") and
            !glib.std.mem.eql(u8, entry.key_ptr.*, "fn_name"))
        {
            return error.UnknownRenderField;
        }
    }

    const label = switch (label_value) {
        .string => |text| blk: {
            if (text.len == 0) return error.EmptyRenderLabel;
            break :blk try allocator.dupe(u8, text);
        },
        else => return error.ExpectedRenderLabelString,
    };
    errdefer allocator.free(label);
    const state_path = switch (state_path_value) {
        .string => |text| blk: {
            try validateStatePath(text);
            break :blk try allocator.dupe(u8, text);
        },
        else => return error.ExpectedRenderStatePathString,
    };
    errdefer allocator.free(state_path);
    const render_fn_name = switch (render_fn_name_value) {
        .string => |text| blk: {
            if (text.len == 0) return error.EmptyRenderFnName;
            break :blk try allocator.dupe(u8, text);
        },
        else => return error.ExpectedRenderFnNameString,
    };
    errdefer allocator.free(render_fn_name);

    return .{
        .label = label,
        .state_path = state_path,
        .render_fn_name = render_fn_name,
    };
}

fn validateStatePath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyRenderStatePath;
    if (path[0] == '/' or path[path.len - 1] == '/') return error.InvalidRenderStatePathBoundary;

    var segment_start: usize = 0;
    for (path, 0..) |ch, idx| {
        if (ch == '.') return error.DotSeparatedRenderStatePath;
        if (ch == '/') {
            if (idx == segment_start) return error.EmptyRenderStatePathSegment;
            segment_start = idx + 1;
        }
    }
    if (segment_start == path.len) return error.EmptyRenderStatePathSegment;
}

fn validateStatePathComptime(comptime path: []const u8) void {
    if (path.len == 0) @compileError("zux.spec.Render.parseJsonValue `state_path` must not be empty");
    if (path[0] == '/' or path[path.len - 1] == '/') {
        @compileError("zux.spec.Render.parseJsonValue `state_path` must not start or end with '/'");
    }

    comptime var segment_start: usize = 0;
    inline for (path, 0..) |ch, idx| {
        if (ch == '.') {
            @compileError("zux.spec.Render.parseJsonValue `state_path` must use '/' separators instead of '.'");
        }
        if (ch == '/') {
            if (idx == segment_start) {
                @compileError("zux.spec.Render.parseJsonValue `state_path` must not contain empty path segments");
            }
            segment_start = idx + 1;
        }
    }
    if (segment_start == path.len) {
        @compileError("zux.spec.Render.parseJsonValue `state_path` must not contain empty path segments");
    }
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}
