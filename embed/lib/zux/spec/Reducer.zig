const glib = @import("glib");
const JsonParser = @import("JsonParser.zig");
const Reducer = @This();

label: []const u8,
reducer_fn_name: []const u8,

pub fn parseSlice(comptime source: []const u8) Reducer {
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
) !Reducer {
    var parsed_value = try glib.std.json.parseFromSlice(
        glib.std.json.Value,
        allocator,
        source,
        .{},
    );
    defer parsed_value.deinit();

    return try parseJsonValue(allocator, parsed_value.value);
}

pub fn deinit(self: *Reducer, allocator: glib.std.mem.Allocator) void {
    allocator.free(self.label);
    allocator.free(self.reducer_fn_name);
}

fn parseFromParser(parser: *JsonParser) Reducer {
    parser.expectByte('{');

    var label: ?[]const u8 = null;
    var reducer_fn_name: ?[]const u8 = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.Reducer.parseSlice requires `label` and `reducer_fn_name` fields");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "label")) {
            if (label != null) {
                @compileError("zux.spec.Reducer.parseSlice duplicate `label` field");
            }
            label = parser.parseString();
            if (label.?.len == 0) {
                @compileError("zux.spec.Reducer.parseSlice `label` must not be empty");
            }
        } else if (comptimeEql(key, "reducer_fn_name") or comptimeEql(key, "fn_name")) {
            if (reducer_fn_name != null) {
                @compileError("zux.spec.Reducer.parseSlice duplicate reducer function field");
            }
            reducer_fn_name = parser.parseString();
            if (reducer_fn_name.?.len == 0) {
                @compileError("zux.spec.Reducer.parseSlice `reducer_fn_name` must not be empty");
            }
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.Reducer.parseSlice only supports `label`, `reducer_fn_name`, and `fn_name` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    return .{
        .label = label orelse @compileError("zux.spec.Reducer.parseSlice requires a `label` field"),
        .reducer_fn_name = reducer_fn_name orelse @compileError("zux.spec.Reducer.parseSlice requires a `reducer_fn_name` or `fn_name` field"),
    };
}

pub fn parseJsonValue(
    allocator: glib.std.mem.Allocator,
    value: glib.std.json.Value,
) !Reducer {
    if (@inComptime()) {
        const object = switch (value) {
            .object => |object| object,
            else => @compileError("zux.spec.Reducer.parseJsonValue expects a JSON object"),
        };

        const label_value = object.get("label") orelse
            @compileError("zux.spec.Reducer.parseJsonValue requires a `label` field");
        const reducer_fn_name_value = object.get("reducer_fn_name") orelse
            object.get("fn_name") orelse
            @compileError("zux.spec.Reducer.parseJsonValue requires a `reducer_fn_name` or `fn_name` field");

        const label = switch (label_value) {
            .string => |text| blk: {
                if (text.len == 0) @compileError("zux.spec.Reducer.parseJsonValue `label` must not be empty");
                break :blk text;
            },
            else => @compileError("zux.spec.Reducer.parseJsonValue `label` must be a JSON string"),
        };
        const reducer_fn_name = switch (reducer_fn_name_value) {
            .string => |text| blk: {
                if (text.len == 0) @compileError("zux.spec.Reducer.parseJsonValue `reducer_fn_name` must not be empty");
                break :blk text;
            },
            else => @compileError("zux.spec.Reducer.parseJsonValue `reducer_fn_name` must be a JSON string"),
        };

        return .{
            .label = label,
            .reducer_fn_name = reducer_fn_name,
        };
    }

    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedReducerObject,
    };

    const label_value = object.get("label") orelse return error.MissingReducerLabel;
    const reducer_fn_name_value = object.get("reducer_fn_name") orelse
        object.get("fn_name") orelse
        return error.MissingReducerFnName;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!glib.std.mem.eql(u8, entry.key_ptr.*, "label") and
            !glib.std.mem.eql(u8, entry.key_ptr.*, "reducer_fn_name") and
            !glib.std.mem.eql(u8, entry.key_ptr.*, "fn_name"))
        {
            return error.UnknownReducerField;
        }
    }

    const label = switch (label_value) {
        .string => |text| blk: {
            if (text.len == 0) return error.EmptyReducerLabel;
            break :blk try allocator.dupe(u8, text);
        },
        else => return error.ExpectedReducerLabelString,
    };
    errdefer allocator.free(label);
    const reducer_fn_name = switch (reducer_fn_name_value) {
        .string => |text| blk: {
            if (text.len == 0) return error.EmptyReducerFnName;
            break :blk try allocator.dupe(u8, text);
        },
        else => return error.ExpectedReducerFnNameString,
    };
    errdefer allocator.free(reducer_fn_name);

    return .{
        .label = label,
        .reducer_fn_name = reducer_fn_name,
    };
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}
