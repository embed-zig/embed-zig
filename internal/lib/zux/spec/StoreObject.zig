const stdz = @import("stdz");
const builtin = stdz.builtin;
const testing_api = @import("testing");
const JsonParser = @import("JsonParser.zig");
const StoreObject = @This();

pub fn make(comptime label: []const u8, comptime State: type) type {
    validateLabel(label);

    return struct {
        pub const Label = label;
        pub const StateType = State;
    };
}

pub fn parseSlice(comptime source: []const u8) type {
    comptime {
        @setEvalBranchQuota(20_000);
    }

    var parser = JsonParser.init(source);
    const parsed = parseStoreObject(&parser);
    parser.finish();

    return make(parsed.label, parsed.StateType);
}

const Doc = struct {
    label: []const u8,
    StateType: type,
};

fn parseStoreObject(parser: *JsonParser) Doc {
    parser.expectByte('{');

    var label: ?[]const u8 = null;
    var state_type: ?type = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.StoreObject.parseSlice requires `label` and `state` fields");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "label")) {
            if (label != null) {
                @compileError("zux.spec.StoreObject.parseSlice duplicate `label` field");
            }
            label = parser.parseString();
            validateLabel(label.?);
        } else if (comptimeEql(key, "state")) {
            if (state_type != null) {
                @compileError("zux.spec.StoreObject.parseSlice duplicate `state` field");
            }
            state_type = parseStructType(parser);
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.StoreObject.parseSlice only supports `label` and `state` fields");
        }

        if (parser.consumeByte(',')) {
            continue;
        }
        parser.expectByte('}');
        break;
    }

    return .{
        .label = label orelse @compileError("zux.spec.StoreObject.parseSlice requires a `label` field"),
        .StateType = state_type orelse @compileError("zux.spec.StoreObject.parseSlice requires a `state` field"),
    };
}

fn parseStructType(parser: *JsonParser) type {
    const field_count = parser.countObjectFields();
    parser.expectByte('{');

    var fields: [field_count]builtin.Type.StructField = undefined;
    var field_index: usize = 0;

    if (parser.consumeByte('}')) {
        return @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    }

    while (true) {
        const field_name = parser.parseString();
        validateFieldName(field_name);
        parser.expectByte(':');

        const field_type = parseFieldType(parser);
        fields[field_index] = .{
            .name = sentinelName(field_name),
            .type = field_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(field_type),
        };
        field_index += 1;

        if (parser.consumeByte(',')) {
            continue;
        }
        parser.expectByte('}');
        break;
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn parseFieldType(parser: *JsonParser) type {
    switch (parser.peekByte()) {
        '"' => return typeFromName(parser.parseString()),
        '{' => return parseStructType(parser),
        else => @compileError("zux.spec.StoreObject state fields must be type-name strings or nested JSON objects"),
    }
}

fn typeFromName(comptime name: []const u8) type {
    if (comptimeEql(name, "bool")) return bool;
    if (comptimeEql(name, "u8")) return u8;
    if (comptimeEql(name, "u16")) return u16;
    if (comptimeEql(name, "u32")) return u32;
    if (comptimeEql(name, "u64")) return u64;
    if (comptimeEql(name, "u128")) return u128;
    if (comptimeEql(name, "usize")) return usize;
    if (comptimeEql(name, "i8")) return i8;
    if (comptimeEql(name, "i16")) return i16;
    if (comptimeEql(name, "i32")) return i32;
    if (comptimeEql(name, "i64")) return i64;
    if (comptimeEql(name, "i128")) return i128;
    if (comptimeEql(name, "isize")) return isize;
    if (comptimeEql(name, "f16")) return f16;
    if (comptimeEql(name, "f32")) return f32;
    if (comptimeEql(name, "f64")) return f64;
    if (comptimeEql(name, "[]const u8")) return []const u8;
    if (comptimeEql(name, "string")) return []const u8;

    @compileError("zux.spec.StoreObject encountered an unsupported type name in JSON");
}

fn validateLabel(comptime label: []const u8) void {
    if (label.len == 0) {
        @compileError("zux.spec.StoreObject labels must not be empty");
    }
}

fn validateFieldName(comptime field_name: []const u8) void {
    if (field_name.len == 0) {
        @compileError("zux.spec.StoreObject state field names must not be empty");
    }
    if (!isIdentStart(field_name[0])) {
        @compileError("zux.spec.StoreObject state field names must start with a letter or underscore");
    }
    inline for (field_name[1..]) |ch| {
        if (!isIdentContinue(ch)) {
            @compileError("zux.spec.StoreObject state field names must be valid Zig identifiers");
        }
    }
}

fn sentinelName(comptime text: []const u8) [:0]const u8 {
    const terminated = text ++ "\x00";
    return terminated[0..text.len :0];
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}

fn isIdentStart(ch: u8) bool {
    return ch == '_' or (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isIdentContinue(ch: u8) bool {
    return isIdentStart(ch) or (ch >= '0' and ch <= '9');
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn parse_from_slice_generates_store_object_type(testing: anytype) !void {
            const Spec = parseSlice(
                \\{
                \\  "label": "counter",
                \\  "state": {
                \\    "ticks": "usize",
                \\    "pressed": "bool"
                \\  }
                \\}
            );

            try testing.expectEqualStrings("counter", Spec.Label);
            try testing.expect(@hasField(Spec.StateType, "ticks"));
            try testing.expect(@hasField(Spec.StateType, "pressed"));
            try testing.expect(@FieldType(Spec.StateType, "ticks") == usize);
            try testing.expect(@FieldType(Spec.StateType, "pressed") == bool);
        }

        fn parse_from_slice_generates_nested_state_type(testing: anytype) !void {
            const Spec = parseSlice(
                \\{
                \\  "label": "session",
                \\  "state": {
                \\    "user": {
                \\      "name": "string",
                \\      "age": "u32"
                \\    },
                \\    "active": "bool"
                \\  }
                \\}
            );

            try testing.expectEqualStrings("session", Spec.Label);
            try testing.expect(@hasField(Spec.StateType, "user"));
            try testing.expect(@hasField(Spec.StateType, "active"));
            try testing.expect(@FieldType(Spec.StateType, "active") == bool);
            try testing.expect(@hasField(@FieldType(Spec.StateType, "user"), "name"));
            try testing.expect(@hasField(@FieldType(Spec.StateType, "user"), "age"));
            try testing.expect(@FieldType(@FieldType(Spec.StateType, "user"), "name") == []const u8);
            try testing.expect(@FieldType(@FieldType(Spec.StateType, "user"), "age") == u32);
        }

        fn make_preserves_label_and_state_type(testing: anytype) !void {
            const State = struct {
                count: usize,
            };
            const Spec = make("counter", State);

            try testing.expectEqualStrings("counter", Spec.Label);
            try testing.expect(Spec.StateType == State);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.parse_from_slice_generates_store_object_type(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.parse_from_slice_generates_nested_state_type(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.make_preserves_label_and_state_type(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
