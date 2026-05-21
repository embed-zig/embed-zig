const glib = @import("glib");
const JsonParser = @import("JsonParser.zig");
const Component = @This();

pub const Kind = union(enum) {
    grouped_button: struct {
        button_count: usize,
    },
    bt: void,
    audio_system: void,
    display: void,
    single_button: ButtonSpec,
    imu: void,
    led_strip: struct {
        pixel_count: usize,
    },
    modem: void,
    nfc: void,
    switch_output: void,
    pwm: void,
    touch: TouchSpec,
    wifi_sta: void,
    wifi_ap: void,
};

pub const ButtonInputType = enum {
    poll,
    virtual,
};

pub const ButtonSpec = struct {
    input_type: ButtonInputType = .poll,
};

pub const TouchSpec = struct {
    target: ?[]const u8 = null,
};

label: []const u8,
id: u32,
kind: Kind,

pub fn parseSlice(comptime source: []const u8) Component {
    return parseSliceWithKindPath("", source);
}

pub fn parseSliceWithKindPath(
    comptime kind_path: []const u8,
    comptime source: []const u8,
) Component {
    comptime {
        @setEvalBranchQuota(40_000);
    }

    if (kind_path.len != 0) {
        return .{
            .label = parseRequiredNonEmptyStringFieldFromObjectSlice(
                source,
                "label",
                "zux.spec.Component.parseSlice component",
            ),
            .id = parseRequiredU32FieldFromObjectSlice(
                source,
                "id",
                "zux.spec.Component.parseSlice component",
            ),
            .kind = parsePathKindSlice(kind_path, source),
        };
    }

    var parser = JsonParser.init(source);
    const parsed = parseFromParser(&parser);
    parser.finish();
    return parsed;
}

pub fn parseAllocSlice(
    allocator: glib.std.mem.Allocator,
    source: []const u8,
) !Component {
    return parseAllocSliceWithKindPath(allocator, "", source);
}

pub fn parseAllocSliceWithKindPath(
    allocator: glib.std.mem.Allocator,
    comptime kind_path: []const u8,
    source: []const u8,
) !Component {
    var parsed_value = try glib.std.json.parseFromSlice(
        glib.std.json.Value,
        allocator,
        source,
        .{},
    );
    defer parsed_value.deinit();

    if (kind_path.len != 0) {
        return try parseJsonValueWithKindPath(allocator, kind_path, parsed_value.value);
    }

    return try parseJsonValue(allocator, parsed_value.value);
}

pub fn deinit(self: *Component, allocator: glib.std.mem.Allocator) void {
    allocator.free(self.label);
    freeRuntimeKind(self.kind, allocator);
}

fn parseFromParser(parser: *JsonParser) Component {
    parser.expectByte('{');

    var label: ?[]const u8 = null;
    var id: ?u32 = null;
    var kind: ?Kind = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.Component.parseSlice requires `label`, `id`, and `kind` fields");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "label")) {
            if (label != null) {
                @compileError("zux.spec.Component.parseSlice duplicate `label` field");
            }
            label = parser.parseString();
            if (label.?.len == 0) {
                @compileError("zux.spec.Component.parseSlice `label` must not be empty");
            }
        } else if (comptimeEql(key, "id")) {
            if (id != null) {
                @compileError("zux.spec.Component.parseSlice duplicate `id` field");
            }
            id = parser.parseU32();
        } else if (comptimeEql(key, "kind")) {
            if (kind != null) {
                @compileError("zux.spec.Component.parseSlice duplicate `kind` field");
            }
            kind = parseKindSlice(parser.parseValueSlice());
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.Component.parseSlice only supports `label`, `id`, and `kind` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    return .{
        .label = label orelse @compileError("zux.spec.Component.parseSlice requires a `label` field"),
        .id = id orelse @compileError("zux.spec.Component.parseSlice requires an `id` field"),
        .kind = kind orelse @compileError("zux.spec.Component.parseSlice requires a `kind` field"),
    };
}

pub fn parseJsonValue(
    allocator: glib.std.mem.Allocator,
    value: glib.std.json.Value,
) !Component {
    if (@inComptime()) {
        const object = expectObjectComptime(
            value,
            "zux.spec.Component.parseJsonValue component",
        );

        return .{
            .label = parseNonEmptyStringFieldComptime(
                object,
                "label",
                "zux.spec.Component.parseJsonValue component",
            ),
            .id = parseRequiredU32FieldComptime(
                object,
                "id",
                "zux.spec.Component.parseJsonValue component",
            ),
            .kind = parseKindValueComptime(
                object.get("kind") orelse
                    @compileError("zux.spec.Component.parseJsonValue component requires a `kind` field"),
            ),
        };
    }

    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedComponentObject,
    };

    const label_value = object.get("label") orelse return error.MissingComponentLabel;
    const id_value = object.get("id") orelse return error.MissingComponentId;
    const kind_value = object.get("kind") orelse return error.MissingComponentKind;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!glib.std.mem.eql(u8, entry.key_ptr.*, "label") and
            !glib.std.mem.eql(u8, entry.key_ptr.*, "id") and
            !glib.std.mem.eql(u8, entry.key_ptr.*, "kind"))
        {
            return error.UnknownComponentField;
        }
    }

    const label = switch (label_value) {
        .string => |text| blk: {
            if (text.len == 0) return error.EmptyComponentLabel;
            break :blk try allocator.dupe(u8, text);
        },
        else => return error.ExpectedComponentLabelString,
    };
    errdefer allocator.free(label);
    const id = switch (id_value) {
        .integer => |int_value| blk: {
            if (int_value < 0) return error.ExpectedComponentIdInteger;
            break :blk @as(u32, @intCast(int_value));
        },
        else => return error.ExpectedComponentIdInteger,
    };
    const kind = try parseKindValue(allocator, kind_value);
    errdefer freeRuntimeKind(kind, allocator);

    return .{
        .label = label,
        .id = id,
        .kind = kind,
    };
}

pub fn parseJsonValueWithKindPath(
    allocator: glib.std.mem.Allocator,
    comptime kind_path: []const u8,
    value: glib.std.json.Value,
) !Component {
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedComponentObject,
    };

    const label = try parseRequiredNonEmptyStringFieldValue(
        allocator,
        object,
        "label",
        error.MissingComponentLabel,
        error.ExpectedComponentLabelString,
        error.EmptyComponentLabel,
    );
    errdefer allocator.free(label);

    const id = try parseRequiredU32FieldValue(
        object,
        "id",
        error.MissingComponentId,
        error.ExpectedComponentIdInteger,
    );

    const kind = try parsePathKindValue(allocator, kind_path, object);
    errdefer freeRuntimeKind(kind, allocator);

    return .{
        .label = label,
        .id = id,
        .kind = kind,
    };
}

fn freeRuntimeKind(kind: Kind, allocator: glib.std.mem.Allocator) void {
    switch (kind) {
        .touch => |touch| {
            if (touch.target) |target| allocator.free(target);
        },
        else => {},
    }
}

fn parseKindValue(
    allocator: glib.std.mem.Allocator,
    value: glib.std.json.Value,
) !Kind {
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedComponentKindObject,
    };

    var iterator = object.iterator();
    const entry = iterator.next() orelse return error.ExpectedComponentKindObject;
    if (iterator.next() != null) return error.InvalidComponentKindObject;

    if (glib.std.mem.eql(u8, entry.key_ptr.*, "grouped_button")) {
        var payload = try glib.std.json.parseFromValue(
            struct { button_count: usize },
            allocator,
            entry.value_ptr.*,
            .{},
        );
        defer payload.deinit();
        return .{
            .grouped_button = .{
                .button_count = payload.value.button_count,
            },
        };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "single_button")) {
        return .{ .single_button = try parseButtonSpecValue(entry.value_ptr.*) };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "audio_system")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .audio_system = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "bt")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .bt = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "display")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .display = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "imu")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .imu = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "led_strip")) {
        var payload = try glib.std.json.parseFromValue(
            struct { pixel_count: usize },
            allocator,
            entry.value_ptr.*,
            .{},
        );
        defer payload.deinit();
        return .{
            .led_strip = .{
                .pixel_count = payload.value.pixel_count,
            },
        };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "modem")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .modem = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "nfc")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .nfc = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "switch")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .switch_output = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "pwm")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .pwm = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "touch")) {
        return .{ .touch = try parseTouchSpecValue(allocator, entry.value_ptr.*) };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "wifi_sta")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .wifi_sta = {} };
    }
    if (glib.std.mem.eql(u8, entry.key_ptr.*, "wifi_ap")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .wifi_ap = {} };
    }

    return error.UnknownComponentKind;
}

fn parseRequiredStringValueSlice(
    comptime source: []const u8,
    comptime context: []const u8,
) []const u8 {
    var parser = JsonParser.init(source);
    const result = parser.parseString();
    parser.finish();
    if (result.len == 0) {
        @compileError(context ++ " must not be empty");
    }
    return result;
}

fn expectEmptyPayload(value: glib.std.json.Value) !void {
    switch (value) {
        .null => return,
        .object => |object| {
            if (object.count() == 0) return;
            return error.ExpectedEmptyComponentPayload;
        },
        else => return error.ExpectedEmptyComponentPayload,
    }
}

fn parseKindSlice(comptime source: []const u8) Kind {
    var parser = JsonParser.init(source);
    parser.expectByte('{');
    if (parser.consumeByte('}')) {
        @compileError("zux.spec.Component.parseSlice component kind must have exactly one entry");
    }

    const kind_name = parser.parseString();
    parser.expectByte(':');
    const payload_source = parser.parseValueSlice();

    if (parser.consumeByte(',')) {
        @compileError("zux.spec.Component.parseSlice component kind must have exactly one entry");
    }
    parser.expectByte('}');
    parser.finish();

    if (comptimeEql(kind_name, "grouped_button")) {
        return .{
            .grouped_button = .{
                .button_count = parseRequiredUsizeFieldFromObjectSlice(
                    payload_source,
                    "button_count",
                    "zux.spec.Component.parseSlice grouped_button payload",
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "single_button")) {
        return .{ .single_button = parseButtonSpecSlice(payload_source) };
    }
    if (comptimeEql(kind_name, "audio_system")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice audio_system payload",
        );
        return .{ .audio_system = {} };
    }
    if (comptimeEql(kind_name, "bt")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice bt payload",
        );
        return .{ .bt = {} };
    }
    if (comptimeEql(kind_name, "display")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice display payload",
        );
        return .{ .display = {} };
    }
    if (comptimeEql(kind_name, "imu")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice imu payload",
        );
        return .{ .imu = {} };
    }
    if (comptimeEql(kind_name, "led_strip")) {
        return .{
            .led_strip = .{
                .pixel_count = parseRequiredUsizeFieldFromObjectSlice(
                    payload_source,
                    "pixel_count",
                    "zux.spec.Component.parseSlice led_strip payload",
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "modem")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice modem payload",
        );
        return .{ .modem = {} };
    }
    if (comptimeEql(kind_name, "nfc")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice nfc payload",
        );
        return .{ .nfc = {} };
    }
    if (comptimeEql(kind_name, "switch")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice switch payload",
        );
        return .{ .switch_output = {} };
    }
    if (comptimeEql(kind_name, "pwm")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice pwm payload",
        );
        return .{ .pwm = {} };
    }
    if (comptimeEql(kind_name, "touch")) {
        return .{ .touch = parseTouchSpecSlice(payload_source) };
    }
    if (comptimeEql(kind_name, "wifi_sta")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice wifi_sta payload",
        );
        return .{ .wifi_sta = {} };
    }
    if (comptimeEql(kind_name, "wifi_ap")) {
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice wifi_ap payload",
        );
        return .{ .wifi_ap = {} };
    }
    @compileError("zux.spec.Component.parseSlice encountered an unknown component kind");
}

fn parsePathKindSlice(comptime kind_path: []const u8, comptime source: []const u8) Kind {
    if (comptimeEql(kind_path, "button/grouped")) {
        return .{
            .grouped_button = .{
                .button_count = parseRequiredUsizeFieldFromObjectSlice(
                    source,
                    "button_count",
                    "zux.spec.Component.parseSlice Component/button/grouped",
                ),
            },
        };
    }
    if (comptimeEql(kind_path, "button/single")) {
        return .{ .single_button = parseButtonSpecSlice(source) };
    }
    if (comptimeEql(kind_path, "audio_system")) {
        return .{ .audio_system = {} };
    }
    if (comptimeEql(kind_path, "bt")) {
        return .{ .bt = {} };
    }
    if (comptimeEql(kind_path, "display")) {
        return .{ .display = {} };
    }
    if (comptimeEql(kind_path, "imu")) {
        return .{ .imu = {} };
    }
    if (comptimeEql(kind_path, "led_strip")) {
        return .{
            .led_strip = .{
                .pixel_count = parseRequiredUsizeFieldFromObjectSlice(
                    source,
                    "pixel_count",
                    "zux.spec.Component.parseSlice Component/led_strip",
                ),
            },
        };
    }
    if (comptimeEql(kind_path, "modem")) {
        return .{ .modem = {} };
    }
    if (comptimeEql(kind_path, "nfc")) {
        return .{ .nfc = {} };
    }
    if (comptimeEql(kind_path, "switch")) {
        return .{ .switch_output = {} };
    }
    if (comptimeEql(kind_path, "pwm")) {
        return .{ .pwm = {} };
    }
    if (comptimeEql(kind_path, "touch")) {
        return .{ .touch = parseTouchSpecSlice(source) };
    }
    if (comptimeEql(kind_path, "wifi/sta")) {
        return .{ .wifi_sta = {} };
    }
    if (comptimeEql(kind_path, "wifi/ap")) {
        return .{ .wifi_ap = {} };
    }
    @compileError("zux.spec.Component.parseSlice encountered an unknown component kind path");
}

fn parsePathKindValue(
    allocator: glib.std.mem.Allocator,
    comptime kind_path: []const u8,
    object: glib.std.json.ObjectMap,
) !Kind {
    if (glib.std.mem.eql(u8, kind_path, "button/grouped")) {
        return .{
            .grouped_button = .{
                .button_count = try parseRequiredUsizeFieldValue(
                    object,
                    "button_count",
                    error.MissingGroupedButtonCount,
                    error.ExpectedGroupedButtonCountInteger,
                ),
            },
        };
    }
    if (glib.std.mem.eql(u8, kind_path, "button/single")) {
        return .{ .single_button = try parseButtonSpecJsonObject(object) };
    }
    if (glib.std.mem.eql(u8, kind_path, "audio_system")) {
        return .{ .audio_system = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "bt")) {
        return .{ .bt = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "display")) {
        return .{ .display = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "imu")) {
        return .{ .imu = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "led_strip")) {
        return .{
            .led_strip = .{
                .pixel_count = try parseRequiredUsizeFieldValue(
                    object,
                    "pixel_count",
                    error.MissingLedStripPixelCount,
                    error.ExpectedLedStripPixelCountInteger,
                ),
            },
        };
    }
    if (glib.std.mem.eql(u8, kind_path, "modem")) {
        return .{ .modem = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "nfc")) {
        return .{ .nfc = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "switch")) {
        return .{ .switch_output = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "pwm")) {
        return .{ .pwm = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "touch")) {
        return .{ .touch = try parseTouchSpecJsonObject(allocator, object) };
    }
    if (glib.std.mem.eql(u8, kind_path, "wifi/sta")) {
        return .{ .wifi_sta = {} };
    }
    if (glib.std.mem.eql(u8, kind_path, "wifi/ap")) {
        return .{ .wifi_ap = {} };
    }
    return error.UnknownComponentKind;
}

fn parseRequiredUsizeFieldFromObjectSlice(
    comptime source: []const u8,
    comptime field_name: []const u8,
    comptime context: []const u8,
) usize {
    var parser = JsonParser.init(source);
    parser.expectByte('{');
    if (parser.consumeByte('}')) {
        @compileError(context ++ " requires `" ++ field_name ++ "`");
    }

    var result: ?usize = null;
    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');
        if (comptimeEql(key, field_name)) {
            result = parser.parseUsize();
        } else {
            _ = parser.parseValueSlice();
        }
        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }
    parser.finish();
    return result orelse @compileError(context ++ " requires `" ++ field_name ++ "`");
}

fn parseRequiredU32FieldFromObjectSlice(
    comptime source: []const u8,
    comptime field_name: []const u8,
    comptime context: []const u8,
) u32 {
    var parser = JsonParser.init(source);
    parser.expectByte('{');
    if (parser.consumeByte('}')) {
        @compileError(context ++ " requires `" ++ field_name ++ "`");
    }

    var result: ?u32 = null;
    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');
        if (comptimeEql(key, field_name)) {
            result = parser.parseU32();
        } else {
            _ = parser.parseValueSlice();
        }
        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }
    parser.finish();
    return result orelse @compileError(context ++ " requires `" ++ field_name ++ "`");
}

fn parseRequiredNonEmptyStringFieldFromObjectSlice(
    comptime source: []const u8,
    comptime field_name: []const u8,
    comptime context: []const u8,
) []const u8 {
    var parser = JsonParser.init(source);
    parser.expectByte('{');
    if (parser.consumeByte('}')) {
        @compileError(context ++ " requires `" ++ field_name ++ "`");
    }

    var result: ?[]const u8 = null;
    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');
        if (comptimeEql(key, field_name)) {
            result = parser.parseString();
            if (result.?.len == 0) {
                @compileError(context ++ " `" ++ field_name ++ "` must not be empty");
            }
        } else {
            _ = parser.parseValueSlice();
        }
        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }
    parser.finish();
    return result orelse @compileError(context ++ " requires `" ++ field_name ++ "`");
}

fn parseRequiredValueFieldFromObjectSlice(
    comptime source: []const u8,
    comptime field_name: []const u8,
    comptime context: []const u8,
) []const u8 {
    var parser = JsonParser.init(source);
    parser.expectByte('{');
    if (parser.consumeByte('}')) {
        @compileError(context ++ " requires `" ++ field_name ++ "`");
    }

    var value_source: ?[]const u8 = null;
    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');
        const next_value = parser.parseValueSlice();
        if (comptimeEql(key, field_name)) {
            value_source = next_value;
        }
        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }
    parser.finish();
    return value_source orelse @compileError(context ++ " requires `" ++ field_name ++ "`");
}

fn parseRequiredNonEmptyStringFieldValue(
    allocator: glib.std.mem.Allocator,
    object: glib.std.json.ObjectMap,
    field_name: []const u8,
    missing_err: anyerror,
    expected_err: anyerror,
    empty_err: anyerror,
) ![]const u8 {
    const value = object.get(field_name) orelse return missing_err;
    return switch (value) {
        .string => |text| blk: {
            if (text.len == 0) return empty_err;
            break :blk try allocator.dupe(u8, text);
        },
        else => expected_err,
    };
}

fn parseOptionalNonEmptyStringFieldValue(
    allocator: glib.std.mem.Allocator,
    value: glib.std.json.Value,
    expected_err: anyerror,
    empty_err: anyerror,
) ![]const u8 {
    return switch (value) {
        .string => |text| blk: {
            if (text.len == 0) return empty_err;
            break :blk try allocator.dupe(u8, text);
        },
        else => expected_err,
    };
}

fn parseButtonSpecValue(value: glib.std.json.Value) !ButtonSpec {
    return switch (value) {
        .null => .{},
        .object => |object| try parseButtonSpecJsonObject(object),
        else => error.ExpectedObject,
    };
}

fn parseButtonSpecJsonObject(object: glib.std.json.ObjectMap) !ButtonSpec {
    const input_type = if (object.get("type")) |value|
        try parseButtonInputTypeValue(value)
    else
        ButtonInputType.poll;
    return .{ .input_type = input_type };
}

fn parseButtonInputTypeValue(value: glib.std.json.Value) !ButtonInputType {
    const text = switch (value) {
        .string => |text| text,
        else => return error.ExpectedString,
    };
    if (glib.std.mem.eql(u8, text, "poll")) return .poll;
    if (glib.std.mem.eql(u8, text, "virtual")) return .virtual;
    return error.UnknownButtonInputType;
}

fn parseButtonSpecSlice(comptime source: []const u8) ButtonSpec {
    return .{
        .input_type = parseButtonInputTypeSlice(source),
    };
}

fn parseButtonInputTypeSlice(comptime source: []const u8) ButtonInputType {
    var parser = JsonParser.init(source);
    switch (parser.peekByte()) {
        'n' => {
            parser.expectNull();
            parser.finish();
            return .poll;
        },
        '{' => {},
        else => @compileError("zux.spec.Component.parseSlice single_button payload must be null or an object"),
    }

    parser.expectByte('{');
    if (parser.consumeByte('}')) {
        parser.finish();
        return .poll;
    }

    var result: ButtonInputType = .poll;
    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');
        if (comptimeEql(key, "type")) {
            const value = parser.parseString();
            result = parseButtonInputTypeName(value);
        } else {
            _ = parser.parseValueSlice();
        }
        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }
    parser.finish();
    return result;
}

fn parseButtonSpecComptime(comptime value: glib.std.json.Value) ButtonSpec {
    return switch (value) {
        .null => .{},
        .object => |object| .{ .input_type = parseButtonInputTypeComptime(object) },
        else => @compileError("zux.spec.Component.parseJsonValue single_button payload must be null or an object"),
    };
}

fn parseButtonInputTypeComptime(comptime object: glib.std.json.ObjectMap) ButtonInputType {
    if (object.get("type")) |value| {
        return switch (value) {
            .string => |text| parseButtonInputTypeName(text),
            else => @compileError("zux.spec.Component button/single `type` must be a string"),
        };
    }
    return .poll;
}

fn parseButtonInputTypeName(comptime text: []const u8) ButtonInputType {
    if (comptimeEql(text, "poll")) return .poll;
    if (comptimeEql(text, "virtual")) return .virtual;
    @compileError("zux.spec.Component button/single `type` must be `poll` or `virtual`");
}

fn parseTouchSpecValue(allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !TouchSpec {
    return switch (value) {
        .null => .{},
        .object => |object| try parseTouchSpecJsonObject(allocator, object),
        else => error.ExpectedObject,
    };
}

fn parseTouchSpecJsonObject(allocator: glib.std.mem.Allocator, object: glib.std.json.ObjectMap) !TouchSpec {
    const target = if (object.get("target")) |value|
        try parseOptionalNonEmptyStringFieldValue(allocator, value, error.ExpectedComponentTargetString, error.EmptyComponentTarget)
    else
        null;
    return .{ .target = target };
}

fn parseTouchSpecSlice(comptime source: []const u8) TouchSpec {
    var parser = JsonParser.init(source);
    switch (parser.peekByte()) {
        'n' => {
            parser.expectNull();
            parser.finish();
            return .{};
        },
        '{' => {},
        else => @compileError("zux.spec.Component touch payload must be null or an object"),
    }

    parser.expectByte('{');
    if (parser.consumeByte('}')) {
        parser.finish();
        return .{};
    }

    var target: ?[]const u8 = null;
    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');
        if (comptimeEql(key, "target")) {
            target = parser.parseString();
            if (target.?.len == 0) {
                @compileError("zux.spec.Component touch `target` must not be empty");
            }
        } else {
            _ = parser.parseValueSlice();
        }
        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }
    parser.finish();
    return .{ .target = target };
}

fn parseTouchSpecComptime(comptime value: glib.std.json.Value) TouchSpec {
    return switch (value) {
        .null => .{},
        .object => |object| .{ .target = parseOptionalTouchTargetComptime(object) },
        else => @compileError("zux.spec.Component touch payload must be null or an object"),
    };
}

fn parseOptionalTouchTargetComptime(comptime object: glib.std.json.ObjectMap) ?[]const u8 {
    if (object.get("target")) |value| {
        return parseNonEmptyStringValueComptime(value, "zux.spec.Component touch `target`");
    }
    return null;
}

fn parseRequiredU32FieldValue(
    object: glib.std.json.ObjectMap,
    field_name: []const u8,
    missing_err: anyerror,
    expected_err: anyerror,
) !u32 {
    const value = object.get(field_name) orelse return missing_err;
    return switch (value) {
        .integer => |int_value| blk: {
            if (int_value < 0) return expected_err;
            break :blk @as(u32, @intCast(int_value));
        },
        else => expected_err,
    };
}

fn parseRequiredUsizeFieldValue(
    object: glib.std.json.ObjectMap,
    field_name: []const u8,
    missing_err: anyerror,
    expected_err: anyerror,
) !usize {
    const value = object.get(field_name) orelse return missing_err;
    return switch (value) {
        .integer => |int_value| blk: {
            if (int_value < 0) return expected_err;
            break :blk @as(usize, @intCast(int_value));
        },
        else => expected_err,
    };
}

fn parseRequiredAlternativeStringFieldValue(
    allocator: glib.std.mem.Allocator,
    object: glib.std.json.ObjectMap,
    first_name: []const u8,
    second_name: []const u8,
    missing_err: anyerror,
    expected_err: anyerror,
    empty_err: anyerror,
) ![]const u8 {
    const value = object.get(first_name) orelse object.get(second_name) orelse return missing_err;
    return switch (value) {
        .string => |text| blk: {
            if (text.len == 0) return empty_err;
            break :blk try allocator.dupe(u8, text);
        },
        else => expected_err,
    };
}

fn parseRequiredAlternativeStringFieldFromObjectSlice(
    comptime source: []const u8,
    comptime first_name: []const u8,
    comptime second_name: []const u8,
    comptime context: []const u8,
) []const u8 {
    var parser = JsonParser.init(source);
    parser.expectByte('{');
    if (parser.consumeByte('}')) {
        @compileError(context ++ " requires a `" ++ first_name ++ "` or `" ++ second_name ++ "` field");
    }

    var result: ?[]const u8 = null;
    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');
        if (comptimeEql(key, first_name) or comptimeEql(key, second_name)) {
            result = parser.parseString();
            if (result.?.len == 0) {
                @compileError(context ++ " string field must not be empty");
            }
        } else {
            _ = parser.parseValueSlice();
        }
        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }
    parser.finish();
    return result orelse @compileError(context ++ " requires a `" ++ first_name ++ "` or `" ++ second_name ++ "` field");
}

fn expectEmptyPayloadSlice(
    comptime source: []const u8,
    comptime context: []const u8,
) void {
    var parser = JsonParser.init(source);
    switch (parser.peekByte()) {
        'n' => parser.expectNull(),
        '{' => {
            parser.expectByte('{');
            if (!parser.consumeByte('}')) {
                _ = parser.parseValueSlice();
                @compileError(context ++ " must be null or an empty object");
            }
        },
        else => @compileError(context ++ " must be null or an empty object"),
    }
    parser.finish();
}

fn parseKindValueComptime(comptime value: glib.std.json.Value) Kind {
    const object = expectObjectComptime(
        value,
        "zux.spec.Component.parseJsonValue component kind",
    );

    var iterator = object.iterator();
    const entry = iterator.next() orelse
        @compileError("zux.spec.Component.parseJsonValue component kind must have exactly one entry");
    if (iterator.next() != null) {
        @compileError("zux.spec.Component.parseJsonValue component kind must have exactly one entry");
    }

    const kind_name = entry.key_ptr.*;
    const payload = entry.value_ptr.*;

    if (comptimeEql(kind_name, "grouped_button")) {
        const payload_object = expectObjectComptime(
            payload,
            "zux.spec.Component.parseJsonValue grouped_button payload",
        );
        return .{
            .grouped_button = .{
                .button_count = parseRequiredUsizeFieldComptime(
                    payload_object,
                    "button_count",
                    "zux.spec.Component.parseJsonValue grouped_button payload",
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "single_button")) {
        return .{ .single_button = parseButtonSpecComptime(payload) };
    }
    if (comptimeEql(kind_name, "audio_system")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue audio_system payload",
        );
        return .{ .audio_system = {} };
    }
    if (comptimeEql(kind_name, "display")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue display payload",
        );
        return .{ .display = {} };
    }
    if (comptimeEql(kind_name, "imu")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue imu payload",
        );
        return .{ .imu = {} };
    }
    if (comptimeEql(kind_name, "led_strip")) {
        const payload_object = expectObjectComptime(
            payload,
            "zux.spec.Component.parseJsonValue led_strip payload",
        );
        return .{
            .led_strip = .{
                .pixel_count = parseRequiredUsizeFieldComptime(
                    payload_object,
                    "pixel_count",
                    "zux.spec.Component.parseJsonValue led_strip payload",
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "modem")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue modem payload",
        );
        return .{ .modem = {} };
    }
    if (comptimeEql(kind_name, "nfc")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue nfc payload",
        );
        return .{ .nfc = {} };
    }
    if (comptimeEql(kind_name, "switch")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue switch payload",
        );
        return .{ .switch_output = {} };
    }
    if (comptimeEql(kind_name, "pwm")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue pwm payload",
        );
        return .{ .pwm = {} };
    }
    if (comptimeEql(kind_name, "touch")) {
        return .{ .touch = parseTouchSpecComptime(payload) };
    }
    if (comptimeEql(kind_name, "wifi_sta")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue wifi_sta payload",
        );
        return .{ .wifi_sta = {} };
    }
    if (comptimeEql(kind_name, "wifi_ap")) {
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue wifi_ap payload",
        );
        return .{ .wifi_ap = {} };
    }
    @compileError("zux.spec.Component.parseJsonValue encountered an unknown component kind");
}

fn expectObjectComptime(
    comptime value: glib.std.json.Value,
    comptime context: []const u8,
) glib.std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => @compileError(context ++ " must be a JSON object"),
    };
}

fn expectEmptyPayloadComptime(
    comptime value: glib.std.json.Value,
    comptime context: []const u8,
) void {
    switch (value) {
        .null => {},
        .object => |object| {
            if (object.count() != 0) {
                @compileError(context ++ " must be null or an empty object");
            }
        },
        else => @compileError(context ++ " must be null or an empty object"),
    }
}

fn parseRequiredU32FieldComptime(
    comptime object: glib.std.json.ObjectMap,
    comptime field_name: []const u8,
    comptime context: []const u8,
) u32 {
    return parseU32ValueComptime(
        object.get(field_name) orelse @compileError(context ++ " requires `" ++ field_name ++ "`"),
        context ++ " `" ++ field_name ++ "`",
    );
}

fn parseRequiredUsizeFieldComptime(
    comptime object: glib.std.json.ObjectMap,
    comptime field_name: []const u8,
    comptime context: []const u8,
) usize {
    return parseUsizeValueComptime(
        object.get(field_name) orelse @compileError(context ++ " requires `" ++ field_name ++ "`"),
        context ++ " `" ++ field_name ++ "`",
    );
}

fn parseNonEmptyStringFieldComptime(
    comptime object: glib.std.json.ObjectMap,
    comptime field_name: []const u8,
    comptime context: []const u8,
) []const u8 {
    return parseNonEmptyStringValueComptime(
        object.get(field_name) orelse @compileError(context ++ " requires `" ++ field_name ++ "`"),
        context ++ " `" ++ field_name ++ "`",
    );
}

fn parseStringValueComptime(
    comptime value: glib.std.json.Value,
    comptime context: []const u8,
) []const u8 {
    return switch (value) {
        .string => |text| text,
        else => @compileError(context ++ " must be a JSON string"),
    };
}

fn parseNonEmptyStringValueComptime(
    comptime value: glib.std.json.Value,
    comptime context: []const u8,
) []const u8 {
    const text = parseStringValueComptime(value, context);
    if (text.len == 0) {
        @compileError(context ++ " must not be empty");
    }
    return text;
}

fn parseU32ValueComptime(
    comptime value: glib.std.json.Value,
    comptime context: []const u8,
) u32 {
    const int_value = switch (value) {
        .integer => |int_value| int_value,
        else => @compileError(context ++ " must be a JSON integer"),
    };
    if (int_value < 0) {
        @compileError(context ++ " must not be negative");
    }
    return @intCast(int_value);
}

fn parseUsizeValueComptime(
    comptime value: glib.std.json.Value,
    comptime context: []const u8,
) usize {
    const int_value = switch (value) {
        .integer => |int_value| int_value,
        else => @compileError(context ++ " must be a JSON integer"),
    };
    if (int_value < 0) {
        @compileError(context ++ " must not be negative");
    }
    return @intCast(int_value);
}

fn parseBoolValueComptime(
    comptime value: glib.std.json.Value,
    comptime context: []const u8,
) bool {
    return switch (value) {
        .bool => |bool_value| bool_value,
        else => @compileError(context ++ " must be a JSON bool"),
    };
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn parses_component_json_slice(allocator: glib.std.mem.Allocator) !void {
            const source =
                \\{
                \\  "label": "buttons",
                \\  "id": 7
                \\}
            ;

            var parsed = try parseAllocSliceWithKindPath(allocator, "button/single", source);
            defer parsed.deinit(allocator);

            try grt.std.testing.expectEqualStrings("buttons", parsed.label);
            try grt.std.testing.expectEqual(@as(u32, 7), parsed.id);
            switch (parsed.kind) {
                .single_button => {},
                else => return error.ExpectedSingleButtonComponent,
            }
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.parses_component_json_slice(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
