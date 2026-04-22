const embed = @import("embed");
const testing_api = @import("testing");
const JsonParser = @import("JsonParser.zig");
const UserStory = @This();

pub const Step = struct {
    tick: ?Tick = null,
    inputs: []const []const u8 = &.{},
    outputs: []const Output = &.{},
};

pub const Tick = struct {
    interval: i128,
    n: usize,
};

pub const Output = struct {
    label: []const u8,
    state: []const u8,
};

name: []const u8 = "",
description: []const u8 = "",
steps: []const Step,

pub fn parseSlice(comptime source: []const u8) UserStory {
    comptime {
        @setEvalBranchQuota(60_000);
    }

    var parser = JsonParser.init(source);
    const story = parseStoryFromParser(&parser);
    parser.finish();
    return story;
}

pub fn deinit(self: *UserStory) void {
    _ = self;
}

pub fn createTestRunner(self: *const UserStory, comptime ZuxApp: type, app: *ZuxApp) testing_api.TestRunner {
    comptime {
        validateCreateTestRunnerApp(ZuxApp);
    }

    const Runner = struct {
        story: *const UserStory,
        app: *ZuxApp,

        pub fn init(runner: *@This(), allocator: embed.mem.Allocator) !void {
            _ = runner;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            runner.app.start(.{ .ticker = .manual }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer runner.app.stop() catch {};

            runner.runSteps(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        fn runSteps(runner: *@This(), allocator: embed.mem.Allocator) !void {
            var tick_seq: u64 = 0;
            var timestamp_ns: i128 = 0;

            for (runner.story.steps) |step| {
                try runner.runOneStep(allocator, step, &tick_seq, &timestamp_ns);
            }
        }

        fn runOneStep(
            runner: *@This(),
            allocator: embed.mem.Allocator,
            step: Step,
            tick_seq: *u64,
            timestamp_ns: *i128,
        ) !void {
            if (step.tick) |tick| {
                for (0..tick.n) |_| {
                    tick_seq.* +%= 1;
                    timestamp_ns.* +%= tick.interval;

                    runner.app.dispatch(.{
                        .origin = .timer,
                        .timestamp_ns = timestamp_ns.*,
                        .body = .{
                            .tick = .{
                                .seq = tick_seq.*,
                            },
                        },
                    }) catch |err| return err;
                }
            }

            for (step.inputs) |event_source| {
                var event_value = try embed.json.parseFromSlice(
                    embed.json.Value,
                    allocator,
                    event_source,
                    .{},
                );
                defer event_value.deinit();
                var event = try decodeJsonValue(ZuxApp.Event, allocator, event_value.value);
                defer freeDecodedValue(ZuxApp.Event, allocator, &event);

                try runner.dispatchInput(event, timestamp_ns.*);
            }

            runner.app.store.tick();

            for (step.outputs) |output| {
                inline for (@typeInfo(ZuxApp.Store.Stores).@"struct".fields) |field| {
                    if (embed.mem.eql(u8, output.label, field.name)) {
                        var state_value = try embed.json.parseFromSlice(
                            embed.json.Value,
                            allocator,
                            output.state,
                            .{},
                        );
                        defer state_value.deinit();
                        const actual_state = @field(runner.app.store.stores, field.name).get();
                        const StateType = @TypeOf(actual_state);
                        if (!try jsonValueMatches(StateType, state_value.value, actual_state)) {
                            embed.debug.print(
                                "zux UserStory mismatch label={s} expected={s} actual={any}\n",
                                .{ output.label, output.state, actual_state },
                            );
                            return error.StateMismatch;
                        }
                        break;
                    }
                } else {
                    return error.UnknownStoreLabel;
                }
            }
        }

        fn dispatchInput(
            runner: *@This(),
            event: ZuxApp.Event,
            timestamp_ns: i128,
        ) !void {
            switch (event) {
                .ledstrip_set_pixels => |value| {
                    try runner.app.set_led_strip_pixels(
                        try ledStripLabelForSourceId(value.source_id),
                        ledStripFrame(value.pixels),
                        value.brightness,
                    );
                },
                .ledstrip_set => |value| {
                    try runner.app.set_led_strip_animated(
                        try ledStripLabelForSourceId(value.source_id),
                        ledStripFrame(value.pixels),
                        value.brightness,
                        value.duration,
                    );
                },
                .ledstrip_flash => |value| {
                    try runner.app.set_led_strip_flash(
                        try ledStripLabelForSourceId(value.source_id),
                        ledStripFrame(value.pixels),
                        value.brightness,
                        value.duration_ns,
                        value.interval_ns,
                    );
                },
                .ledstrip_pingpong => |value| {
                    try runner.app.set_led_strip_pingpong(
                        try ledStripLabelForSourceId(value.source_id),
                        ledStripFrame(value.from_pixels),
                        ledStripFrame(value.to_pixels),
                        value.brightness,
                        value.duration_ns,
                        value.interval_ns,
                    );
                },
                .ledstrip_rotate => |value| {
                    try runner.app.set_led_strip_rotate(
                        try ledStripLabelForSourceId(value.source_id),
                        ledStripFrame(value.pixels),
                        value.brightness,
                        value.duration_ns,
                        value.interval_ns,
                    );
                },
                else => {
                    runner.app.dispatch(.{
                        .origin = .manual,
                        .timestamp_ns = timestamp_ns,
                        .body = event,
                    }) catch |err| return err;
                },
            }
        }

        fn ledStripLabelForSourceId(source_id: u32) !ZuxApp.PeriphLabel {
            inline for (0..ZuxApp.registries.ledstrip.len) |i| {
                const periph = ZuxApp.registries.ledstrip.periphs[i];
                if (source_id == periph.id) {
                    return @field(ZuxApp.PeriphLabel, periph.label);
                }
            }

            return error.UnknownLedStripSourceId;
        }

        fn ledStripFrame(pixels: anytype) ZuxApp.FrameType {
            var frame: ZuxApp.FrameType = .{};
            const count = @min(frame.pixels.len, pixels.len);
            for (0..count) |i| {
                frame.pixels[i] = pixels[i];
            }
            return frame;
        }

        pub fn deinit(runner: *@This(), allocator: embed.mem.Allocator) void {
            _ = runner;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = undefined;
    };

    Holder.runner = .{
        .story = self,
        .app = app,
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

fn parseStoryFromParser(parser: *JsonParser) UserStory {
    parser.expectByte('{');

    var name: ?[]const u8 = null;
    var description: []const u8 = "";
    var steps: ?[]const Step = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.UserStory.parseSlice requires `name` and `steps` fields");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "name")) {
            if (name != null) {
                @compileError("zux.spec.UserStory.parseSlice duplicate `name` field");
            }
            name = parser.parseString();
        } else if (comptimeEql(key, "description")) {
            description = parser.parseString();
        } else if (comptimeEql(key, "steps")) {
            if (steps != null) {
                @compileError("zux.spec.UserStory.parseSlice duplicate `steps` field");
            }
            steps = parseStepArray(parser.parseValueSlice());
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.UserStory.parseSlice only supports `name`, `description`, and `steps` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    return .{
        .name = name orelse @compileError("zux.spec.UserStory.parseSlice requires a `name` field"),
        .description = description,
        .steps = steps orelse @compileError("zux.spec.UserStory.parseSlice requires a `steps` field"),
    };
}

fn parseStepArray(comptime source: []const u8) []const Step {
    var parser = JsonParser.init(source);
    const steps = comptime blk: {
        const step_count = parser.countArrayItems();
        parser.expectByte('[');

        var next: [step_count]Step = undefined;
        if (!parser.consumeByte(']')) {
            var index: usize = 0;
            while (true) {
                next[index] = parseStep(parser.parseValueSlice());
                index += 1;

                if (parser.consumeByte(',')) continue;
                parser.expectByte(']');
                break;
            }
        }
        parser.finish();
        break :blk next;
    };
    return steps[0..];
}

fn parseStep(comptime source: []const u8) Step {
    var parser = JsonParser.init(source);
    parser.expectByte('{');

    var tick: ?Tick = null;
    var inputs: []const []const u8 = &.{};
    var outputs: []const Output = &.{};

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.UserStory.parseSlice step must include at least one of `tick`, `inputs`, or `outputs`");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "tick")) {
            tick = parseTick(parser.parseValueSlice());
        } else if (comptimeEql(key, "inputs")) {
            inputs = parseInputArray(parser.parseValueSlice());
        } else if (comptimeEql(key, "outputs")) {
            outputs = parseOutputArray(parser.parseValueSlice());
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.UserStory.parseSlice step only supports `tick`, `inputs`, and `outputs` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    parser.finish();

    if (tick == null and inputs.len == 0 and outputs.len == 0) {
        @compileError("zux.spec.UserStory.parseSlice step must include at least one of `tick`, `inputs`, or `outputs`");
    }

    return .{
        .tick = tick,
        .inputs = inputs,
        .outputs = outputs,
    };
}

fn parseTick(comptime source: []const u8) Tick {
    var parser = JsonParser.init(source);
    parser.expectByte('{');

    var interval: ?i128 = null;
    var n: ?usize = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.UserStory.parseSlice tick requires `interval` and `n`");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "interval")) {
            interval = parser.parseI128();
        } else if (comptimeEql(key, "n")) {
            n = parser.parseUsize();
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.UserStory.parseSlice tick only supports `interval` and `n` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    parser.finish();

    return .{
        .interval = interval orelse @compileError("zux.spec.UserStory.parseSlice tick requires an `interval` field"),
        .n = n orelse @compileError("zux.spec.UserStory.parseSlice tick requires an `n` field"),
    };
}

fn parseInputArray(comptime source: []const u8) []const []const u8 {
    var parser = JsonParser.init(source);
    const inputs = comptime blk: {
        const input_count = parser.countArrayItems();
        parser.expectByte('[');

        var next: [input_count][]const u8 = undefined;
        if (!parser.consumeByte(']')) {
            var index: usize = 0;
            while (true) {
                next[index] = parser.parseValueSlice();
                index += 1;

                if (parser.consumeByte(',')) continue;
                parser.expectByte(']');
                break;
            }
        }
        parser.finish();
        break :blk next;
    };
    return inputs[0..];
}

fn parseOutputArray(comptime source: []const u8) []const Output {
    var parser = JsonParser.init(source);
    const outputs = comptime blk: {
        const output_count = parser.countArrayItems();
        parser.expectByte('[');

        var next: [output_count]Output = undefined;
        if (!parser.consumeByte(']')) {
            var index: usize = 0;
            while (true) {
                next[index] = parseOutput(parser.parseValueSlice());
                index += 1;

                if (parser.consumeByte(',')) continue;
                parser.expectByte(']');
                break;
            }
        }
        parser.finish();
        break :blk next;
    };
    return outputs[0..];
}

fn parseOutput(comptime source: []const u8) Output {
    var parser = JsonParser.init(source);
    parser.expectByte('{');

    var label: ?[]const u8 = null;
    var state: ?[]const u8 = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.spec.UserStory.parseSlice output requires `label` and `state`");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "label")) {
            label = parser.parseString();
        } else if (comptimeEql(key, "state")) {
            state = parser.parseValueSlice();
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.spec.UserStory.parseSlice output only supports `label` and `state` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }

    parser.finish();

    return .{
        .label = label orelse @compileError("zux.spec.UserStory.parseSlice output requires a `label` field"),
        .state = state orelse @compileError("zux.spec.UserStory.parseSlice output requires a `state` field"),
    };
}

fn validateCreateTestRunnerApp(comptime ZuxApp: type) void {
    comptime {
        if (!@hasDecl(ZuxApp, "Message")) {
            @compileError("zux.spec.UserStory.createTestRunner requires ZuxApp.Message");
        }
        if (!@hasDecl(ZuxApp, "Event")) {
            @compileError("zux.spec.UserStory.createTestRunner requires ZuxApp.Event");
        }
        if (!@hasDecl(ZuxApp, "StartConfig")) {
            @compileError("zux.spec.UserStory.createTestRunner requires ZuxApp.StartConfig");
        }
        if (!@hasDecl(ZuxApp, "start")) {
            @compileError("zux.spec.UserStory.createTestRunner requires ZuxApp.start");
        }
        if (!@hasDecl(ZuxApp, "stop")) {
            @compileError("zux.spec.UserStory.createTestRunner requires ZuxApp.stop");
        }
        if (ZuxApp.Store == void) {
            @compileError("zux.spec.UserStory.createTestRunner requires ZuxApp.Store");
        }
        if (!@hasDecl(ZuxApp.Store, "Stores")) {
            @compileError("zux.spec.UserStory.createTestRunner requires ZuxApp.Store.Stores");
        }
        _ = @as(*const fn (*ZuxApp, ZuxApp.Message) anyerror!void, &ZuxApp.dispatch);
        _ = @as(*const fn (*ZuxApp, ZuxApp.StartConfig) anyerror!void, &ZuxApp.start);
        _ = @as(*const fn (*ZuxApp) anyerror!void, &ZuxApp.stop);
    }
}

fn decodeJsonValue(
    comptime T: type,
    allocator: embed.mem.Allocator,
    value: embed.json.Value,
) !T {
    comptime {
        @setEvalBranchQuota(20_000);
    }

    return switch (@typeInfo(T)) {
        .void => {},

        .bool => switch (value) {
            .bool => |bool_value| bool_value,
            else => error.ExpectedBool,
        },

        .int => switch (value) {
            .integer => |int_value| try castJsonInteger(T, int_value),
            else => error.ExpectedInteger,
        },

        .float => switch (value) {
            .integer => |int_value| @as(T, @floatFromInt(int_value)),
            .float => |float_value| @as(T, @floatCast(float_value)),
            else => error.ExpectedFloat,
        },

        .@"enum" => |info| switch (value) {
            .string => |name| blk: {
                inline for (info.fields) |field| {
                    if (embed.mem.eql(u8, name, field.name)) {
                        break :blk @field(T, field.name);
                    }
                }
                return error.UnknownEnumTag;
            },
            else => error.ExpectedEnumString,
        },

        .optional => |info| switch (value) {
            .null => null,
            else => try decodeJsonValue(info.child, allocator, value),
        },

        .array => |info| if (info.child == u8) switch (value) {
            .string => |string_value| blk: {
                if (string_value.len > info.len) return error.ArrayLengthMismatch;

                var result: T = [_]u8{0} ** info.len;
                @memcpy(result[0..string_value.len], string_value);
                break :blk result;
            },
            .array => |array| blk: {
                if (array.items.len > info.len) return error.ArrayLengthMismatch;

                var result: T = [_]u8{0} ** info.len;
                for (array.items, 0..) |item, i| {
                    result[i] = try decodeJsonValue(u8, allocator, item);
                }
                break :blk result;
            },
            else => error.ExpectedArray,
        } else switch (value) {
            .array => |array| blk: {
                if (array.items.len != info.len) return error.ArrayLengthMismatch;

                var result: T = undefined;
                for (array.items, 0..) |item, i| {
                    result[i] = try decodeJsonValue(info.child, allocator, item);
                }
                break :blk result;
            },
            else => error.ExpectedArray,
        },

        .pointer => |info| switch (info.size) {
            .slice => switch (value) {
                .string => |string_value| {
                    if (info.child != u8) return error.ExpectedArray;
                    return try allocator.dupe(u8, string_value);
                },
                .array => |array| blk: {
                    const out = try allocator.alloc(info.child, array.items.len);
                    for (array.items, 0..) |item, i| {
                        out[i] = try decodeJsonValue(info.child, allocator, item);
                    }
                    break :blk out;
                },
                else => error.ExpectedArray,
            },
            else => error.UnsupportedPointerType,
        },

        .@"struct" => |info| blk: {
            const object = switch (value) {
                .object => |object| object,
                else => return error.ExpectedObject,
            };

            var result: T = undefined;
            var seen: [info.fields.len]bool = [_]bool{false} ** info.fields.len;

            inline for (info.fields, 0..) |field, i| {
                if (field.default_value_ptr) |default_ptr| {
                    @field(result, field.name) = @as(
                        *const field.type,
                        @ptrCast(@alignCast(default_ptr)),
                    ).*;
                    seen[i] = true;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                    seen[i] = true;
                }
            }

            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                var matched = false;

                inline for (info.fields, 0..) |field, i| {
                    if (embed.mem.eql(u8, entry.key_ptr.*, field.name)) {
                        @field(result, field.name) = try decodeJsonValue(
                            field.type,
                            allocator,
                            entry.value_ptr.*,
                        );
                        seen[i] = true;
                        matched = true;
                    }
                }

                if (!matched) return error.UnknownObjectField;
            }

            inline for (info.fields, 0..) |field, i| {
                if (!seen[i] and field.default_value_ptr == null and @typeInfo(field.type) != .optional) {
                    return error.MissingObjectField;
                }
            }

            break :blk result;
        },

        .@"union" => |info| {
            if (info.tag_type == null) return error.UnsupportedUnionType;

            const object = switch (value) {
                .object => |object| object,
                else => return error.ExpectedUnionObject,
            };

            var iterator = object.iterator();
            const entry = iterator.next() orelse return error.ExpectedUnionObject;
            if (iterator.next() != null) return error.InvalidUnionObject;

            inline for (info.fields) |field| {
                if (embed.mem.eql(u8, entry.key_ptr.*, field.name)) {
                    return @unionInit(
                        T,
                        field.name,
                        try decodeJsonValue(field.type, allocator, entry.value_ptr.*),
                    );
                }
            }

            return error.UnknownUnionField;
        },

        else => error.UnsupportedJsonType,
    };
}

fn castJsonInteger(comptime T: type, int_value: i64) !T {
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        const max = (@as(i128, 1) << (info.bits - 1)) - 1;
        const min = -(@as(i128, 1) << (info.bits - 1));
        const value = @as(i128, int_value);
        if (value < min or value > max) return error.IntegerOutOfRange;
        return @intCast(int_value);
    }

    if (int_value < 0) return error.IntegerOutOfRange;
    const max = (@as(u128, 1) << info.bits) - 1;
    const value = @as(u128, @intCast(int_value));
    if (value > max) return error.IntegerOutOfRange;
    return @intCast(int_value);
}

fn jsonValueMatches(
    comptime T: type,
    expected: embed.json.Value,
    actual: T,
) !bool {
    return switch (@typeInfo(T)) {
        .void => true,

        .bool => switch (expected) {
            .bool => |value| value == actual,
            else => error.ExpectedBool,
        },

        .int => switch (expected) {
            .integer => |value| actual == try castJsonInteger(T, value),
            else => error.ExpectedInteger,
        },

        .float => switch (expected) {
            .integer => |value| actual == @as(T, @floatFromInt(value)),
            .float => |value| actual == @as(T, @floatCast(value)),
            else => error.ExpectedFloat,
        },

        .@"enum" => switch (expected) {
            .string => |name| embed.mem.eql(u8, name, @tagName(actual)),
            else => error.ExpectedEnumString,
        },

        .optional => |info| switch (expected) {
            .null => actual == null,
            else => if (actual) |child| try jsonValueMatches(info.child, expected, child) else false,
        },

        .array => |info| if (info.child == u8) switch (expected) {
            .string => |text| text.len <= info.len and embed.mem.eql(u8, text, actual[0..text.len]),
            .array => |array| blk: {
                if (array.items.len > info.len) return error.ArrayLengthMismatch;
                for (array.items, 0..) |item, i| {
                    if (!(try jsonValueMatches(u8, item, actual[i]))) break :blk false;
                }
                break :blk true;
            },
            else => error.ExpectedArray,
        } else switch (expected) {
            .array => |array| blk: {
                if (array.items.len != info.len) return error.ArrayLengthMismatch;
                for (array.items, 0..) |item, i| {
                    if (!(try jsonValueMatches(info.child, item, actual[i]))) break :blk false;
                }
                break :blk true;
            },
            else => error.ExpectedArray,
        },

        .pointer => |info| switch (info.size) {
            .slice => switch (expected) {
                .string => |text| {
                    if (info.child != u8) return error.ExpectedArray;
                    return embed.mem.eql(u8, text, actual);
                },
                .array => |array| blk: {
                    if (array.items.len != actual.len) return false;
                    for (array.items, 0..) |item, i| {
                        if (!(try jsonValueMatches(info.child, item, actual[i]))) break :blk false;
                    }
                    break :blk true;
                },
                else => error.ExpectedArray,
            },
            else => error.UnsupportedPointerType,
        },

        .@"struct" => |info| blk: {
            const object = switch (expected) {
                .object => |object| object,
                else => return error.ExpectedObject,
            };

            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                var matched = false;

                inline for (info.fields) |field| {
                    if (embed.mem.eql(u8, entry.key_ptr.*, field.name)) {
                        if (!(try jsonValueMatches(
                            field.type,
                            entry.value_ptr.*,
                            @field(actual, field.name),
                        ))) return false;
                        matched = true;
                    }
                }

                if (!matched) return error.UnknownObjectField;
            }

            break :blk true;
        },

        .@"union" => |info| blk: {
            if (info.tag_type == null) return error.UnsupportedUnionType;

            const object = switch (expected) {
                .object => |object| object,
                else => return error.ExpectedUnionObject,
            };

            var iterator = object.iterator();
            const entry = iterator.next() orelse return error.ExpectedUnionObject;
            if (iterator.next() != null) return error.InvalidUnionObject;

            switch (actual) {
                inline else => |payload, tag| {
                    if (!embed.mem.eql(u8, entry.key_ptr.*, @tagName(tag))) break :blk false;
                    break :blk try jsonValueMatches(@TypeOf(payload), entry.value_ptr.*, payload);
                },
            }
        },

        else => error.UnsupportedJsonType,
    };
}

fn freeDecodedValue(
    comptime T: type,
    allocator: embed.mem.Allocator,
    value: *const T,
) void {
    switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum" => {},

        .optional => |info| {
            if (value.*) |*child| {
                freeDecodedValue(info.child, allocator, child);
            }
        },

        .array => |info| {
            for (&value.*) |*item| {
                freeDecodedValue(info.child, allocator, item);
            }
        },

        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child != u8) {
                    for (value.*) |*item| {
                        freeDecodedValue(info.child, allocator, item);
                    }
                }
                allocator.free(value.*);
            },
            else => {},
        },

        .@"struct" => |info| {
            inline for (info.fields) |field| {
                const field_ptr = &@field(value.*, field.name);
                freeDecodedValue(field.type, allocator, field_ptr);
            }
        },

        .@"union" => |info| {
            if (info.tag_type == null) return;

            switch (value.*) {
                inline else => |*payload| {
                    freeDecodedValue(@TypeOf(payload.*), allocator, payload);
                },
            }
        },

        else => {},
    }
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
        fn parses_story_json(testing: anytype, allocator: lib.mem.Allocator) !void {
            const source =
                \\{
                \\  "name": "counter story",
                \\  "description": "drives a counter through ticks and button input",
                \\  "steps": [
                \\    {
                \\      "tick": {
                \\        "interval": 42,
                \\        "n": 2
                \\      }
                \\    },
                \\    {
                \\      "inputs": [
                \\        {
                \\          "raw_single_button": {
                \\            "source_id": 7,
                \\            "pressed": true
                \\          }
                \\        }
                \\      ]
                \\    },
                \\    {
                \\      "outputs": [
                \\        {
                \\          "label": "counter",
                \\          "state": {
                \\            "ticks": 1,
                \\            "pressed": false
                \\          }
                \\        }
                \\      ]
                \\    }
                \\  ]
                \\}
            ;

            var parsed = comptime parseSlice(source);
            defer parsed.deinit();

            try testing.expectEqualStrings("counter story", parsed.name);
            try testing.expectEqualStrings("drives a counter through ticks and button input", parsed.description);
            try testing.expectEqual(@as(usize, 3), parsed.steps.len);

            if (parsed.steps[0].tick) |tick| {
                try testing.expectEqual(@as(i128, 42), tick.interval);
                try testing.expectEqual(@as(usize, 2), tick.n);
            } else {
                return error.ExpectedTickStep;
            }

            if (parsed.steps[1].inputs.len != 1) {
                return error.ExpectedDispatchStep;
            }
            var input_value = try embed.json.parseFromSlice(
                embed.json.Value,
                allocator,
                parsed.steps[1].inputs[0],
                .{},
            );
            defer input_value.deinit();
            switch (input_value.value) {
                .object => |object| try testing.expect(object.get("raw_single_button") != null),
                else => return error.ExpectedDispatchObject,
            }

            if (parsed.steps[2].outputs.len != 1) {
                return error.ExpectedStateCheckStep;
            }
            try testing.expectEqualStrings("counter", parsed.steps[2].outputs[0].label);
            var state_value = try embed.json.parseFromSlice(
                embed.json.Value,
                allocator,
                parsed.steps[2].outputs[0].state,
                .{},
            );
            defer state_value.deinit();
            switch (state_value.value) {
                .object => |object| try testing.expect(object.get("ticks") != null),
                else => return error.ExpectedStateObject,
            }
        }

        fn parses_escaped_story_strings(testing: anytype, allocator: lib.mem.Allocator) !void {
            _ = allocator;

            const source =
                \\{
                \\  "name": "counter \uD83D\uDE00",
                \\  "description": "line 1\nline 2",
                \\  "steps": [
                \\    {
                \\      "tick": {
                \\        "interval": 1,
                \\        "n": 1
                \\      }
                \\    }
                \\  ]
                \\}
            ;

            var parsed = comptime parseSlice(source);
            defer parsed.deinit();

            try testing.expectEqualStrings("counter \xf0\x9f\x98\x80", parsed.name);
            try testing.expectEqualStrings("line 1\nline 2", parsed.description);
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

            TestCase.parses_story_json(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.parses_escaped_story_strings(testing, allocator) catch |err| {
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
