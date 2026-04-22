const stdz = @import("stdz");
const testing_api = @import("testing");
const ui_overlay = @import("../component/ui/overlay.zig");
const route = @import("../component/ui/route.zig");
const ui_selection = @import("../component/ui/selection.zig");
const JsonParser = @import("JsonParser.zig");
const Component = @This();

pub const Kind = union(enum) {
    grouped_button: struct {
        button_count: usize,
    },
    single_button: void,
    imu: void,
    led_strip: struct {
        pixel_count: usize,
    },
    modem: void,
    nfc: void,
    wifi_sta: void,
    wifi_ap: void,
    router: struct {
        initial_item: route.Router.Item,
    },
    flow: struct {
        type_name: []const u8,
    },
    overlay: struct {
        initial_state: ui_overlay.State,
    },
    selection: struct {
        initial_state: ui_selection.State,
    },
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
    allocator: stdz.mem.Allocator,
    source: []const u8,
) !Component {
    return parseAllocSliceWithKindPath(allocator, "", source);
}

pub fn parseAllocSliceWithKindPath(
    allocator: stdz.mem.Allocator,
    comptime kind_path: []const u8,
    source: []const u8,
) !Component {
    var parsed_value = try stdz.json.parseFromSlice(
        stdz.json.Value,
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

pub fn deinit(self: *Component, allocator: stdz.mem.Allocator) void {
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
    allocator: stdz.mem.Allocator,
    value: stdz.json.Value,
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
        if (!stdz.mem.eql(u8, entry.key_ptr.*, "label") and
            !stdz.mem.eql(u8, entry.key_ptr.*, "id") and
            !stdz.mem.eql(u8, entry.key_ptr.*, "kind"))
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
    allocator: stdz.mem.Allocator,
    comptime kind_path: []const u8,
    value: stdz.json.Value,
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

fn freeRuntimeKind(kind: Kind, allocator: stdz.mem.Allocator) void {
    switch (kind) {
        .flow => |flow| allocator.free(flow.type_name),
        else => {},
    }
}

fn parseKindValue(
    allocator: stdz.mem.Allocator,
    value: stdz.json.Value,
) !Kind {
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedComponentKindObject,
    };

    var iterator = object.iterator();
    const entry = iterator.next() orelse return error.ExpectedComponentKindObject;
    if (iterator.next() != null) return error.InvalidComponentKindObject;

    if (stdz.mem.eql(u8, entry.key_ptr.*, "grouped_button")) {
        var payload = try stdz.json.parseFromValue(
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
    if (stdz.mem.eql(u8, entry.key_ptr.*, "single_button")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .single_button = {} };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "imu")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .imu = {} };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "led_strip")) {
        var payload = try stdz.json.parseFromValue(
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
    if (stdz.mem.eql(u8, entry.key_ptr.*, "modem")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .modem = {} };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "nfc")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .nfc = {} };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "wifi_sta")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .wifi_sta = {} };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "wifi_ap")) {
        try expectEmptyPayload(entry.value_ptr.*);
        return .{ .wifi_ap = {} };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "router")) {
        var payload = try stdz.json.parseFromValue(
            struct { initial_item: route.Router.Item },
            allocator,
            entry.value_ptr.*,
            .{},
        );
        defer payload.deinit();
        return .{
            .router = .{
                .initial_item = payload.value.initial_item,
            },
        };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "flow")) {
        const payload = switch (entry.value_ptr.*) {
            .object => |payload| payload,
            else => return error.ExpectedFlowComponentObject,
        };
        const type_name_value = payload.get("type_name") orelse payload.get("type") orelse return error.MissingFlowTypeName;
        const type_name = switch (type_name_value) {
            .string => |text| blk: {
                if (text.len == 0) return error.EmptyFlowTypeName;
                break :blk try allocator.dupe(u8, text);
            },
            else => return error.ExpectedFlowTypeNameString,
        };
        return .{
            .flow = .{
                .type_name = type_name,
            },
        };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "overlay")) {
        var payload = try stdz.json.parseFromValue(
            struct { initial_state: ui_overlay.State },
            allocator,
            entry.value_ptr.*,
            .{},
        );
        defer payload.deinit();
        return .{
            .overlay = .{
                .initial_state = payload.value.initial_state,
            },
        };
    }
    if (stdz.mem.eql(u8, entry.key_ptr.*, "selection")) {
        var payload = try stdz.json.parseFromValue(
            struct { initial_state: ui_selection.State },
            allocator,
            entry.value_ptr.*,
            .{},
        );
        defer payload.deinit();
        return .{
            .selection = .{
                .initial_state = payload.value.initial_state,
            },
        };
    }

    return error.UnknownComponentKind;
}

fn expectEmptyPayload(value: stdz.json.Value) !void {
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
        expectEmptyPayloadSlice(
            payload_source,
            "zux.spec.Component.parseSlice single_button payload",
        );
        return .{ .single_button = {} };
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
    if (comptimeEql(kind_name, "router")) {
        return .{
            .router = .{
                .initial_item = parseRouterItemSlice(
                    parseRequiredValueFieldFromObjectSlice(
                        payload_source,
                        "initial_item",
                        "zux.spec.Component.parseSlice router payload",
                    ),
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "flow")) {
        return .{
            .flow = .{
                .type_name = parseRequiredAlternativeStringFieldFromObjectSlice(
                    payload_source,
                    "type_name",
                    "type",
                    "zux.spec.Component.parseSlice flow payload",
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "overlay")) {
        return .{
            .overlay = .{
                .initial_state = parseOverlayStateSlice(
                    parseRequiredValueFieldFromObjectSlice(
                        payload_source,
                        "initial_state",
                        "zux.spec.Component.parseSlice overlay payload",
                    ),
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "selection")) {
        return .{
            .selection = .{
                .initial_state = parseSelectionStateSlice(
                    parseRequiredValueFieldFromObjectSlice(
                        payload_source,
                        "initial_state",
                        "zux.spec.Component.parseSlice selection payload",
                    ),
                ),
            },
        };
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
        return .{ .single_button = {} };
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
    if (comptimeEql(kind_path, "wifi/sta")) {
        return .{ .wifi_sta = {} };
    }
    if (comptimeEql(kind_path, "wifi/ap")) {
        return .{ .wifi_ap = {} };
    }
    if (comptimeEql(kind_path, "ui/route")) {
        return .{
            .router = .{
                .initial_item = parseRouterItemSlice(
                    parseRequiredValueFieldFromObjectSlice(
                        source,
                        "initial_item",
                        "zux.spec.Component.parseSlice Component/ui/route",
                    ),
                ),
            },
        };
    }
    if (comptimeEql(kind_path, "ui/flow")) {
        return .{
            .flow = .{
                .type_name = parseRequiredAlternativeStringFieldFromObjectSlice(
                    source,
                    "type_name",
                    "type",
                    "zux.spec.Component.parseSlice Component/ui/flow",
                ),
            },
        };
    }
    if (comptimeEql(kind_path, "ui/overlay")) {
        return .{
            .overlay = .{
                .initial_state = parseOverlayStateSlice(
                    parseRequiredValueFieldFromObjectSlice(
                        source,
                        "initial_state",
                        "zux.spec.Component.parseSlice Component/ui/overlay",
                    ),
                ),
            },
        };
    }
    if (comptimeEql(kind_path, "ui/selection")) {
        return .{
            .selection = .{
                .initial_state = parseSelectionStateSlice(
                    parseRequiredValueFieldFromObjectSlice(
                        source,
                        "initial_state",
                        "zux.spec.Component.parseSlice Component/ui/selection",
                    ),
                ),
            },
        };
    }

    @compileError("zux.spec.Component.parseSlice encountered an unknown component kind path");
}

fn parsePathKindValue(
    allocator: stdz.mem.Allocator,
    comptime kind_path: []const u8,
    object: stdz.json.ObjectMap,
) !Kind {
    if (stdz.mem.eql(u8, kind_path, "button/grouped")) {
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
    if (stdz.mem.eql(u8, kind_path, "button/single")) {
        return .{ .single_button = {} };
    }
    if (stdz.mem.eql(u8, kind_path, "imu")) {
        return .{ .imu = {} };
    }
    if (stdz.mem.eql(u8, kind_path, "led_strip")) {
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
    if (stdz.mem.eql(u8, kind_path, "modem")) {
        return .{ .modem = {} };
    }
    if (stdz.mem.eql(u8, kind_path, "nfc")) {
        return .{ .nfc = {} };
    }
    if (stdz.mem.eql(u8, kind_path, "wifi/sta")) {
        return .{ .wifi_sta = {} };
    }
    if (stdz.mem.eql(u8, kind_path, "wifi/ap")) {
        return .{ .wifi_ap = {} };
    }
    if (stdz.mem.eql(u8, kind_path, "ui/route")) {
        const initial_item_value = object.get("initial_item") orelse return error.MissingRouterInitialItem;
        var payload = try stdz.json.parseFromValue(route.Router.Item, allocator, initial_item_value, .{});
        defer payload.deinit();
        return .{
            .router = .{
                .initial_item = payload.value,
            },
        };
    }
    if (stdz.mem.eql(u8, kind_path, "ui/flow")) {
        return .{
            .flow = .{
                .type_name = try parseRequiredAlternativeStringFieldValue(
                    allocator,
                    object,
                    "type_name",
                    "type",
                    error.MissingFlowTypeName,
                    error.ExpectedFlowTypeNameString,
                    error.EmptyFlowTypeName,
                ),
            },
        };
    }
    if (stdz.mem.eql(u8, kind_path, "ui/overlay")) {
        const initial_state_value = object.get("initial_state") orelse return error.MissingOverlayInitialState;
        var payload = try stdz.json.parseFromValue(
            ui_overlay.State,
            allocator,
            initial_state_value,
            .{},
        );
        defer payload.deinit();
        return .{
            .overlay = .{
                .initial_state = payload.value,
            },
        };
    }
    if (stdz.mem.eql(u8, kind_path, "ui/selection")) {
        const initial_state_value = object.get("initial_state") orelse return error.MissingSelectionInitialState;
        var payload = try stdz.json.parseFromValue(
            ui_selection.State,
            allocator,
            initial_state_value,
            .{},
        );
        defer payload.deinit();
        return .{
            .selection = .{
                .initial_state = payload.value,
            },
        };
    }

    return error.UnknownComponentKind;
}

fn parseRouterItemSlice(comptime source: []const u8) route.Router.Item {
    var parser = JsonParser.init(source);
    parser.expectByte('{');

    var item: route.Router.Item = .{};
    if (parser.consumeByte('}')) {
        parser.finish();
        return item;
    }

    while (true) {
        const field_name = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(field_name, "screen_id")) {
            item.screen_id = parser.parseU32();
        } else if (comptimeEql(field_name, "arg0")) {
            item.arg0 = parser.parseU32();
        } else if (comptimeEql(field_name, "arg1")) {
            item.arg1 = parser.parseU32();
        } else if (comptimeEql(field_name, "flags")) {
            item.flags = parser.parseU32();
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.Component.parseSlice router initial_item contains an unknown field");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    parser.finish();
    return item;
}

fn parseOverlayStateSlice(comptime source: []const u8) ui_overlay.State {
    var parser = JsonParser.init(source);
    parser.expectByte('{');

    var state: ui_overlay.State = .{};
    if (parser.consumeByte('}')) {
        parser.finish();
        return state;
    }

    while (true) {
        const field_name = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(field_name, "visible")) {
            state.visible = parser.parseBool();
        } else if (comptimeEql(field_name, "name")) {
            const fields = ui_overlay.State.nameFields(parser.parseString()) catch
                @compileError("zux.spec.Component.parseSlice overlay initial_state `name` is too long");
            state.name = fields.name;
            state.name_len = fields.name_len;
        } else if (comptimeEql(field_name, "blocking")) {
            state.blocking = parser.parseBool();
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.Component.parseSlice overlay initial_state contains an unknown field");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    parser.finish();
    return state;
}

fn parseSelectionStateSlice(comptime source: []const u8) ui_selection.State {
    var parser = JsonParser.init(source);
    parser.expectByte('{');

    var state: ui_selection.State = .{};
    if (parser.consumeByte('}')) {
        parser.finish();
        return state;
    }

    while (true) {
        const field_name = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(field_name, "index")) {
            state.index = parser.parseUsize();
        } else if (comptimeEql(field_name, "count")) {
            state.count = parser.parseUsize();
        } else if (comptimeEql(field_name, "loop")) {
            state.loop = parser.parseBool();
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.Component.parseSlice selection initial_state contains an unknown field");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    parser.finish();
    return state;
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
    allocator: stdz.mem.Allocator,
    object: stdz.json.ObjectMap,
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

fn parseRequiredU32FieldValue(
    object: stdz.json.ObjectMap,
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
    object: stdz.json.ObjectMap,
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
    allocator: stdz.mem.Allocator,
    object: stdz.json.ObjectMap,
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

fn parseKindValueComptime(comptime value: stdz.json.Value) Kind {
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
        expectEmptyPayloadComptime(
            payload,
            "zux.spec.Component.parseJsonValue single_button payload",
        );
        return .{ .single_button = {} };
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
    if (comptimeEql(kind_name, "router")) {
        const payload_object = expectObjectComptime(
            payload,
            "zux.spec.Component.parseJsonValue router payload",
        );
        return .{
            .router = .{
                .initial_item = parseRouterItemComptime(
                    payload_object.get("initial_item") orelse
                        @compileError("zux.spec.Component.parseJsonValue router payload requires an `initial_item` field"),
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "flow")) {
        const payload_object = expectObjectComptime(
            payload,
            "zux.spec.Component.parseJsonValue flow payload",
        );
        return .{
            .flow = .{
                .type_name = parseNonEmptyStringValueComptime(
                    payload_object.get("type_name") orelse
                        payload_object.get("type") orelse
                        @compileError("zux.spec.Component.parseJsonValue flow payload requires a `type_name` or `type` field"),
                    "zux.spec.Component.parseJsonValue flow payload `type_name`",
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "overlay")) {
        const payload_object = expectObjectComptime(
            payload,
            "zux.spec.Component.parseJsonValue overlay payload",
        );
        return .{
            .overlay = .{
                .initial_state = parseOverlayStateComptime(
                    payload_object.get("initial_state") orelse
                        @compileError("zux.spec.Component.parseJsonValue overlay payload requires an `initial_state` field"),
                ),
            },
        };
    }
    if (comptimeEql(kind_name, "selection")) {
        const payload_object = expectObjectComptime(
            payload,
            "zux.spec.Component.parseJsonValue selection payload",
        );
        return .{
            .selection = .{
                .initial_state = parseSelectionStateComptime(
                    payload_object.get("initial_state") orelse
                        @compileError("zux.spec.Component.parseJsonValue selection payload requires an `initial_state` field"),
                ),
            },
        };
    }

    @compileError("zux.spec.Component.parseJsonValue encountered an unknown component kind");
}

fn parseRouterItemComptime(comptime value: stdz.json.Value) route.Router.Item {
    const object = expectObjectComptime(
        value,
        "zux.spec.Component.parseJsonValue router initial_item",
    );
    var item: route.Router.Item = .{};
    var iterator = object.iterator();

    while (iterator.next()) |entry| {
        const field_name = entry.key_ptr.*;
        if (comptimeEql(field_name, "screen_id")) {
            item.screen_id = parseU32ValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue router initial_item `screen_id`",
            );
        } else if (comptimeEql(field_name, "arg0")) {
            item.arg0 = parseU32ValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue router initial_item `arg0`",
            );
        } else if (comptimeEql(field_name, "arg1")) {
            item.arg1 = parseU32ValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue router initial_item `arg1`",
            );
        } else if (comptimeEql(field_name, "flags")) {
            item.flags = parseU32ValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue router initial_item `flags`",
            );
        } else {
            @compileError("zux.spec.Component.parseJsonValue router initial_item contains an unknown field");
        }
    }

    return item;
}

fn parseOverlayStateComptime(comptime value: stdz.json.Value) ui_overlay.State {
    const object = expectObjectComptime(
        value,
        "zux.spec.Component.parseJsonValue overlay initial_state",
    );
    var state: ui_overlay.State = .{};
    var iterator = object.iterator();

    while (iterator.next()) |entry| {
        const field_name = entry.key_ptr.*;
        if (comptimeEql(field_name, "visible")) {
            state.visible = parseBoolValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue overlay initial_state `visible`",
            );
        } else if (comptimeEql(field_name, "name")) {
            const fields = ui_overlay.State.nameFields(
                parseStringValueComptime(
                    entry.value_ptr.*,
                    "zux.spec.Component.parseJsonValue overlay initial_state `name`",
                ),
            ) catch @compileError("zux.spec.Component.parseJsonValue overlay initial_state `name` is too long");
            state.name = fields.name;
            state.name_len = fields.name_len;
        } else if (comptimeEql(field_name, "blocking")) {
            state.blocking = parseBoolValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue overlay initial_state `blocking`",
            );
        } else {
            @compileError("zux.spec.Component.parseJsonValue overlay initial_state contains an unknown field");
        }
    }

    return state;
}

fn parseSelectionStateComptime(comptime value: stdz.json.Value) ui_selection.State {
    const object = expectObjectComptime(
        value,
        "zux.spec.Component.parseJsonValue selection initial_state",
    );
    var state: ui_selection.State = .{};
    var iterator = object.iterator();

    while (iterator.next()) |entry| {
        const field_name = entry.key_ptr.*;
        if (comptimeEql(field_name, "index")) {
            state.index = parseUsizeValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue selection initial_state `index`",
            );
        } else if (comptimeEql(field_name, "count")) {
            state.count = parseUsizeValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue selection initial_state `count`",
            );
        } else if (comptimeEql(field_name, "loop")) {
            state.loop = parseBoolValueComptime(
                entry.value_ptr.*,
                "zux.spec.Component.parseJsonValue selection initial_state `loop`",
            );
        } else {
            @compileError("zux.spec.Component.parseJsonValue selection initial_state contains an unknown field");
        }
    }

    return state;
}

fn expectObjectComptime(
    comptime value: stdz.json.Value,
    comptime context: []const u8,
) stdz.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => @compileError(context ++ " must be a JSON object"),
    };
}

fn expectEmptyPayloadComptime(
    comptime value: stdz.json.Value,
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
    comptime object: stdz.json.ObjectMap,
    comptime field_name: []const u8,
    comptime context: []const u8,
) u32 {
    return parseU32ValueComptime(
        object.get(field_name) orelse @compileError(context ++ " requires `" ++ field_name ++ "`"),
        context ++ " `" ++ field_name ++ "`",
    );
}

fn parseRequiredUsizeFieldComptime(
    comptime object: stdz.json.ObjectMap,
    comptime field_name: []const u8,
    comptime context: []const u8,
) usize {
    return parseUsizeValueComptime(
        object.get(field_name) orelse @compileError(context ++ " requires `" ++ field_name ++ "`"),
        context ++ " `" ++ field_name ++ "`",
    );
}

fn parseNonEmptyStringFieldComptime(
    comptime object: stdz.json.ObjectMap,
    comptime field_name: []const u8,
    comptime context: []const u8,
) []const u8 {
    return parseNonEmptyStringValueComptime(
        object.get(field_name) orelse @compileError(context ++ " requires `" ++ field_name ++ "`"),
        context ++ " `" ++ field_name ++ "`",
    );
}

fn parseStringValueComptime(
    comptime value: stdz.json.Value,
    comptime context: []const u8,
) []const u8 {
    return switch (value) {
        .string => |text| text,
        else => @compileError(context ++ " must be a JSON string"),
    };
}

fn parseNonEmptyStringValueComptime(
    comptime value: stdz.json.Value,
    comptime context: []const u8,
) []const u8 {
    const text = parseStringValueComptime(value, context);
    if (text.len == 0) {
        @compileError(context ++ " must not be empty");
    }
    return text;
}

fn parseU32ValueComptime(
    comptime value: stdz.json.Value,
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
    comptime value: stdz.json.Value,
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
    comptime value: stdz.json.Value,
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

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn parses_component_json_slice(testing: anytype, allocator: lib.mem.Allocator) !void {
            const source =
                \\{
                \\  "label": "buttons",
                \\  "id": 7
                \\}
            ;

            var parsed = try parseAllocSliceWithKindPath(allocator, "button/single", source);
            defer parsed.deinit(allocator);

            try testing.expectEqualStrings("buttons", parsed.label);
            try testing.expectEqual(@as(u32, 7), parsed.id);
            switch (parsed.kind) {
                .single_button => {},
                else => return error.ExpectedSingleButtonComponent,
            }
        }

        fn parses_component_flow_json_slice(testing: anytype, allocator: lib.mem.Allocator) !void {
            const source =
                \\{
                \\  "label": "pairing",
                \\  "id": 31,
                \\  "type_name": "PairingFlow"
                \\}
            ;

            var parsed = try parseAllocSliceWithKindPath(allocator, "ui/flow", source);
            defer parsed.deinit(allocator);

            try testing.expectEqualStrings("pairing", parsed.label);
            try testing.expectEqual(@as(u32, 31), parsed.id);
            switch (parsed.kind) {
                .flow => |flow_component| try testing.expectEqualStrings("PairingFlow", flow_component.type_name),
                else => return error.ExpectedFlowComponent,
            }
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const testing = lib.testing;

            TestCase.parses_component_json_slice(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.parses_component_flow_json_slice(testing, allocator) catch |err| {
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
