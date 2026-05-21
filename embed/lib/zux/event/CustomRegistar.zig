const glib = @import("glib");

const Custom = @import("Custom.zig");
const CustomRegistar = @This();

pub fn make(comptime EventTypes: anytype) type {
    comptime validateEventTypes(EventTypes);

    return struct {
        const Self = @This();

        pub const event_types = EventTypes;
        pub const count: usize = EventTypes.len;
        pub const Entry = struct {
            register_id: u32,
            event_name: []const u8,
            type_name: []const u8,
        };
        pub const entries: [count]Entry = blk: {
            var next: [count]Entry = undefined;
            for (EventTypes, 0..) |T, i| {
                next[i] = .{
                    .register_id = @intCast(i),
                    .event_name = T.event_name,
                    .type_name = @typeName(T),
                };
            }
            break :blk next;
        };

        pub fn init() Self {
            return .{};
        }

        pub fn idForName(_: Self, event_name: []const u8) !u32 {
            inline for (entries) |entry| {
                if (glib.std.mem.eql(u8, event_name, entry.event_name)) {
                    return entry.register_id;
                }
            }
            return error.UnknownCustomEventType;
        }

        pub fn nameForId(_: Self, register_id: u32) ![]const u8 {
            inline for (entries) |entry| {
                if (register_id == entry.register_id) {
                    return entry.event_name;
                }
            }
            return error.UnknownCustomEventRegisterId;
        }

        pub fn idForType(_: Self, comptime T: type) u32 {
            return comptime idForEventType(EventTypes, T);
        }

        pub fn eventType(comptime event_name: []const u8) type {
            inline for (EventTypes) |T| {
                if (glib.std.mem.eql(u8, event_name, T.event_name)) {
                    return T;
                }
            }
            @compileError("unknown custom event: " ++ event_name);
        }

        pub fn eventTypeForId(comptime register_id: u32) type {
            inline for (EventTypes, 0..) |T, i| {
                if (register_id == @as(u32, @intCast(i))) {
                    return T;
                }
            }
            @compileError("unknown custom event register id");
        }

        pub fn initEvent(self: Self, comptime T: type, source_id: u32, payload: *T) Custom {
            return Custom.initRegistered(self.idForType(T), source_id, payload);
        }

        pub fn decodeJson(self: Self, allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !Custom {
            const input = try parseJsonInput(value);
            const register_id = try self.idForName(input.event_name);
            inline for (EventTypes, 0..) |T, i| {
                if (register_id == @as(u32, @intCast(i))) {
                    const payload = try T.decodeJson(allocator, input.payload);
                    return Custom.initRegistered(register_id, input.source_id, payload);
                }
            }
            return error.UnknownCustomEventRegisterId;
        }

        const JsonInput = struct {
            event_name: []const u8,
            source_id: u32,
            payload: glib.std.json.Value,
        };

        fn parseJsonInput(json_value: glib.std.json.Value) !JsonInput {
            const object = switch (json_value) {
                .object => |object| object,
                else => return error.ExpectedObject,
            };

            var event_name: ?[]const u8 = null;
            var source_id: ?u32 = null;
            var payload: ?glib.std.json.Value = null;

            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (glib.std.mem.eql(u8, entry.key_ptr.*, "type")) {
                    event_name = switch (entry.value_ptr.*) {
                        .string => |string_value| string_value,
                        else => return error.ExpectedString,
                    };
                } else if (glib.std.mem.eql(u8, entry.key_ptr.*, "source_id")) {
                    source_id = switch (entry.value_ptr.*) {
                        .integer => |int_value| try castU32(int_value),
                        else => return error.ExpectedInteger,
                    };
                } else if (glib.std.mem.eql(u8, entry.key_ptr.*, "payload")) {
                    payload = entry.value_ptr.*;
                } else {
                    return error.UnknownObjectField;
                }
            }

            return .{
                .event_name = event_name orelse return error.MissingObjectField,
                .source_id = source_id orelse return error.MissingObjectField,
                .payload = payload orelse return error.MissingObjectField,
            };
        }
    };
}

pub const Empty = make(.{});

fn validateEventTypes(comptime EventTypes: anytype) void {
    if (EventTypes.len > glib.std.math.maxInt(u32)) {
        @compileError("zux.event.CustomRegistar supports at most maxInt(u32) event types");
    }

    inline for (EventTypes, 0..) |T, i| {
        comptime {
            const event_name: []const u8 = T.event_name;
            if (event_name.len == 0) {
                @compileError("zux.event.CustomRegistar event_name must not be empty");
            }
            _ = @as(*const fn (glib.std.mem.Allocator, glib.std.json.Value) anyerror!*T, &T.decodeJson);
            _ = @as(*const fn (*T) void, &T.deinit);
        }

        inline for (EventTypes, 0..) |Other, j| {
            if (i < j and glib.std.mem.eql(u8, T.event_name, Other.event_name)) {
                @compileError("zux.event.CustomRegistar duplicate event_name '" ++ T.event_name ++ "'");
            }
        }
    }
}

fn idForEventType(comptime EventTypes: anytype, comptime T: type) u32 {
    inline for (EventTypes, 0..) |EventType, i| {
        if (T == EventType) return @intCast(i);
    }
    @compileError("zux.event.CustomRegistar event type is not registered: " ++ @typeName(T));
}

fn castU32(value: i64) !u32 {
    if (value < 0) return error.IntegerOutOfRange;
    if (@as(u64, @intCast(value)) > glib.std.math.maxInt(u32)) return error.IntegerOutOfRange;
    return @intCast(value);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn assigns_ids_and_creates_events(allocator: glib.std.mem.Allocator) !void {
            var deinit_count: u32 = 0;

            const Progress = struct {
                pub const event_name = "test.progress";

                allocator: glib.std.mem.Allocator,
                deinit_count: *u32,
                value: u32,

                pub fn decodeJson(mem_allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
                    _ = value;
                    const payload = try mem_allocator.create(@This());
                    payload.* = .{
                        .allocator = mem_allocator,
                        .deinit_count = undefined,
                        .value = 0,
                    };
                    return payload;
                }

                pub fn deinit(payload: *@This()) void {
                    payload.deinit_count.* += 1;
                    payload.allocator.destroy(payload);
                }
            };

            const Done = struct {
                pub const event_name = "test.done";

                allocator: glib.std.mem.Allocator,

                pub fn decodeJson(mem_allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
                    _ = value;
                    const payload = try mem_allocator.create(@This());
                    payload.* = .{
                        .allocator = mem_allocator,
                    };
                    return payload;
                }

                pub fn deinit(payload: *@This()) void {
                    payload.allocator.destroy(payload);
                }
            };

            const Registar = make(.{ Progress, Done });
            const registar = Registar.init();
            try grt.std.testing.expectEqual(@as(u32, 0), try registar.idForName("test.progress"));
            try grt.std.testing.expectEqual(@as(u32, 1), try registar.idForName("test.done"));
            try grt.std.testing.expectEqualStrings("test.progress", try registar.nameForId(0));
            try grt.std.testing.expectEqual(@as(u32, 0), registar.idForType(Progress));
            try grt.std.testing.expect(Registar.eventType("test.progress") == Progress);
            try grt.std.testing.expect(Registar.eventType("test.done") == Done);
            try grt.std.testing.expect(Registar.eventTypeForId(0) == Progress);
            try grt.std.testing.expect(Registar.eventTypeForId(1) == Done);
            try grt.std.testing.expect(Registar.event_types[0] == Progress);

            const payload = try allocator.create(Progress);
            payload.* = .{
                .allocator = allocator,
                .deinit_count = &deinit_count,
                .value = 42,
            };
            const custom = registar.initEvent(Progress, 7, payload);
            try grt.std.testing.expectEqual(@as(u32, 0), custom.register_id);
            try grt.std.testing.expectEqual(@as(u32, 7), custom.source_id);
            try grt.std.testing.expectEqual(@as(u32, 42), (try custom.as(Progress)).value);
            custom.deinit();
            try grt.std.testing.expectEqual(@as(u32, 1), deinit_count);
        }

        fn decodes_json_by_event_name(allocator: glib.std.mem.Allocator) !void {
            const Payload = struct {
                pub const event_name = "test.payload";

                allocator: glib.std.mem.Allocator,
                value: u32,

                pub fn decodeJson(mem_allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
                    const object = switch (value) {
                        .object => |object| object,
                        else => return error.ExpectedObject,
                    };
                    const field = object.get("value") orelse return error.MissingObjectField;
                    const decoded_value: u32 = switch (field) {
                        .integer => |int_value| @intCast(int_value),
                        else => return error.ExpectedInteger,
                    };

                    const payload = try mem_allocator.create(@This());
                    payload.* = .{
                        .allocator = mem_allocator,
                        .value = decoded_value,
                    };
                    return payload;
                }

                pub fn deinit(payload: *@This()) void {
                    payload.allocator.destroy(payload);
                }
            };

            const source =
                \\{
                \\  "type": "test.payload",
                \\  "source_id": 33,
                \\  "payload": {
                \\    "value": 55
                \\  }
                \\}
            ;

            var parsed = try glib.std.json.parseFromSlice(glib.std.json.Value, allocator, source, .{});
            defer parsed.deinit();

            const Registar = make(.{Payload});
            const custom = try Registar.init().decodeJson(allocator, parsed.value);
            defer custom.deinit();

            try grt.std.testing.expectEqual(@as(u32, 0), custom.register_id);
            try grt.std.testing.expectEqual(@as(u32, 33), custom.source_id);
            try grt.std.testing.expectEqual(@as(u32, 55), (try custom.as(Payload)).value);
        }
    };

    const Runner = struct {
        pub fn init(runner: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = runner;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = runner;

            TestCase.assigns_ids_and_creates_events(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.decodes_json_by_event_name(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(runner: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = runner;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
