const glib = @import("glib");
const BranchNode = @import("BranchNode.zig");
const Emitter = @import("Emitter.zig");
const Message = @import("Message.zig");
const Node = @import("Node.zig");

const route_count = @typeInfo(Message.Kind).@"enum".fields.len;
const ValidationError = error{
    UnterminatedSwitch,
    EmptySequence,
    InvalidNodeSpan,
    UnexpectedCaseMarker,
    UnexpectedSwitchTerminator,
    SwitchBodyEmpty,
    SwitchExpectedCase,
    DuplicateCase,
    EmptyCase,
    NoCasesInSwitch,
    ParsePastEnd,
    UnexpectedEndSwitchInCase,
};

pub const default_max_ops: usize = 512;

pub const BuilderOptions = struct {
    max_ops: usize = default_max_ops,
};

pub fn Builder(comptime options: BuilderOptions) type {
    const max_ops = options.max_ops;
    comptime {
        if (max_ops == 0) {
            @compileError("zux.pipeline.NodeBuilder.Builder max_ops must be > 0");
        }
    }
    return struct {
        const Self = @This();

        const Op = union(enum) {
            node: []const u8,
            begin_switch: void,
            route: Message.Kind,
            end_switch: void,
        };

        const SwitchFrame = struct {
            seen_case: bool = false,
            case_has_item: bool = false,
        };

        ops: [max_ops]Op = undefined,
        len: usize = 0,

        tags: [max_ops][]const u8 = undefined,
        tag_len: usize = 0,
        switch_count: usize = 0,

        frames: [max_ops]SwitchFrame = undefined,
        frame_len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn addNode(self: *Self, comptime tag: anytype) void {
            const tag_name = labelText(tag);
            self.ensureCanAppendItem("addNode");
            self.append(.{ .node = tag_name });
            self.markCurrentCaseHasItem();
            self.appendUniqueTag(tag_name);
        }

        pub fn beginSwitch(self: *Self) void {
            self.ensureCanAppendItem("beginSwitch");
            self.append(.{ .begin_switch = {} });
            self.markCurrentCaseHasItem();
            self.switch_count += 1;
            self.pushSwitchFrame();
        }

        pub fn addCase(self: *Self, comptime kind: Message.Kind) void {
            const frame = self.requireOpenSwitch("addCase");
            if (frame.seen_case and !frame.case_has_item) {
                @compileError("zux.pipeline.NodeBuilder.Builder.addCase cannot follow an empty case body");
            }
            frame.seen_case = true;
            frame.case_has_item = false;
            self.append(.{ .route = kind });
        }

        pub fn endSwitch(self: *Self) void {
            const frame = self.requireOpenSwitch("endSwitch");
            if (!frame.seen_case) {
                @compileError("zux.pipeline.NodeBuilder.Builder.endSwitch requires at least one case");
            }
            if (!frame.case_has_item) {
                @compileError("zux.pipeline.NodeBuilder.Builder.endSwitch cannot close an empty case body");
            }
            self.append(.{ .end_switch = {} });
            self.frame_len -= 1;
        }

        pub fn make(comptime self: Self) type {
            self.validate() catch |err| @compileError(validationErrorMessage(err));

            const GeneratedConfig = makeConfig(self);

            return struct {
                const Bypass = struct {
                    out: ?Emitter = null,

                    pub fn bindOutput(node_impl: *@This(), out: Emitter) void {
                        node_impl.out = out;
                    }

                    pub fn process(node_impl: *@This(), message: Message) !usize {
                        if (node_impl.out) |out| {
                            try out.emit(message);
                            return 1;
                        }
                        return 0;
                    }
                };

                pub const BuiltConfig = GeneratedConfig;
                pub const Config = BuiltConfig;

                pub fn build(config: *BuiltConfig) Node {
                    if (self.len == 0) {
                        return makeBypassNode();
                    }
                    var next_branch_index: usize = 0;
                    return buildSeqRange(self, 0, self.len, config, &next_branch_index, null);
                }

                fn makeBypassNode() Node {
                    const Holder = struct {
                        var impl: Bypass = .{};
                    };
                    Holder.impl = .{};
                    return Node.init(Bypass, &Holder.impl);
                }
            };
        }

        fn validate(comptime self: Self) ValidationError!void {
            try validateBuilder(self);
        }

        fn append(self: *Self, op: Op) void {
            if (self.len >= max_ops) {
                @compileError("zux.pipeline.NodeBuilder.Builder exceeded max_ops");
            }
            self.ops[self.len] = op;
            self.len += 1;
        }

        fn appendUniqueTag(self: *Self, comptime tag: []const u8) void {
            inline for (0..self.tag_len) |i| {
                if (comptimeEql(self.tags[i], tag)) return;
            }
            self.tags[self.tag_len] = tag;
            self.tag_len += 1;
        }

        fn markCurrentCaseHasItem(self: *Self) void {
            if (self.frame_len == 0) return;
            self.frames[self.frame_len - 1].case_has_item = true;
        }

        fn pushSwitchFrame(self: *Self) void {
            if (self.frame_len >= max_ops) {
                @compileError("zux.pipeline.NodeBuilder.Builder exceeded max nested switches");
            }
            self.frames[self.frame_len] = .{};
            self.frame_len += 1;
        }

        fn currentFrame(self: *Self) ?*SwitchFrame {
            if (self.frame_len == 0) return null;
            return &self.frames[self.frame_len - 1];
        }

        fn requireOpenSwitch(self: *Self, comptime action: []const u8) *SwitchFrame {
            return self.currentFrame() orelse @compileError(
                "zux.pipeline.NodeBuilder.Builder." ++ action ++ " requires an open switch",
            );
        }

        fn ensureCanAppendItem(self: *Self, comptime action: []const u8) void {
            if (self.currentFrame()) |frame| {
                if (!frame.seen_case) {
                    @compileError(
                        "zux.pipeline.NodeBuilder.Builder." ++ action ++ " requires calling addCase(...) first",
                    );
                }
            }
        }
    };
}

fn validationErrorMessage(err: ValidationError) []const u8 {
    return switch (err) {
        error.UnterminatedSwitch => "zux.pipeline.NodeBuilder.Builder.make found an unterminated switch",
        error.EmptySequence => "zux.pipeline.NodeBuilder encountered an empty sequence",
        error.InvalidNodeSpan => "zux.pipeline.NodeBuilder node item had an invalid span",
        error.UnexpectedCaseMarker => "zux.pipeline.NodeBuilder encountered an unexpected case marker",
        error.UnexpectedSwitchTerminator => "zux.pipeline.NodeBuilder encountered an unexpected switch terminator",
        error.SwitchBodyEmpty => "zux.pipeline.NodeBuilder switch body cannot be empty",
        error.SwitchExpectedCase => "zux.pipeline.NodeBuilder switch expected addCase(...) markers",
        error.DuplicateCase => "zux.pipeline.NodeBuilder switch cannot define the same case twice",
        error.EmptyCase => "zux.pipeline.NodeBuilder switch case cannot be empty",
        error.NoCasesInSwitch => "zux.pipeline.NodeBuilder switch requires at least one case",
        error.ParsePastEnd => "zux.pipeline.NodeBuilder tried to parse beyond the end of the op stream",
        error.UnexpectedEndSwitchInCase => "zux.pipeline.NodeBuilder saw an unexpected endSwitch() inside a case body",
    };
}

fn validateBuilder(comptime builder: anytype) ValidationError!void {
    if (builder.len == 0) return;
    if (builder.frame_len != 0) return error.UnterminatedSwitch;
    try validateSeqRange(builder, 0, builder.len);
}

fn validateSeqRange(comptime builder: anytype, comptime start: usize, comptime end: usize) ValidationError!void {
    if (start >= end) return error.EmptySequence;

    const item_end = comptime try validatedNextItemEnd(builder, start, end);
    if (item_end == end) {
        return validateItemRange(builder, start, item_end);
    }

    try validateSeqRange(builder, item_end, end);
    try validateItemRange(builder, start, item_end);
}

fn validateItemRange(comptime builder: anytype, comptime start: usize, comptime end: usize) ValidationError!void {
    switch (builder.ops[start]) {
        .node => {
            if (end != start + 1) return error.InvalidNodeSpan;
        },
        .begin_switch => try validateSwitchRange(builder, start, end),
        .route => return error.UnexpectedCaseMarker,
        .end_switch => return error.UnexpectedSwitchTerminator,
    }
}

fn validateSwitchRange(comptime builder: anytype, comptime start: usize, comptime end: usize) ValidationError!void {
    if (end <= start + 2) return error.SwitchBodyEmpty;

    comptime var seen_routes: [route_count]bool = [_]bool{false} ** route_count;
    comptime var i = start + 1;
    comptime var case_count: usize = 0;

    inline while (i < end - 1) {
        const kind = switch (builder.ops[i]) {
            .route => |route_kind| route_kind,
            else => return error.SwitchExpectedCase,
        };

        const kind_index = @intFromEnum(kind);
        if (seen_routes[kind_index]) return error.DuplicateCase;
        seen_routes[kind_index] = true;

        const body_start = i + 1;
        const body_end = comptime try validatedNextCaseStartOrSwitchEnd(builder, body_start, end - 1);
        if (body_start >= body_end) return error.EmptyCase;

        try validateSeqRange(builder, body_start, body_end);
        case_count += 1;
        i = body_end;
    }

    if (case_count == 0) return error.NoCasesInSwitch;
}

fn validatedNextItemEnd(comptime builder: anytype, comptime start: usize, comptime limit: usize) ValidationError!usize {
    if (start >= limit) return error.ParsePastEnd;

    return switch (builder.ops[start]) {
        .node => start + 1,
        .begin_switch => validatedFindMatchingSwitchEnd(builder, start, limit),
        .route => error.UnexpectedCaseMarker,
        .end_switch => error.UnexpectedSwitchTerminator,
    };
}

fn validatedFindMatchingSwitchEnd(comptime builder: anytype, comptime start: usize, comptime limit: usize) ValidationError!usize {
    comptime var depth: usize = 1;
    comptime var i = start + 1;

    inline while (i < limit) : (i += 1) {
        switch (builder.ops[i]) {
            .begin_switch => depth += 1,
            .end_switch => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }

    return error.UnterminatedSwitch;
}

fn validatedNextCaseStartOrSwitchEnd(
    comptime builder: anytype,
    comptime start: usize,
    comptime switch_end_index: usize,
) ValidationError!usize {
    comptime var nested_depth: usize = 0;
    comptime var i = start;

    inline while (i < switch_end_index) : (i += 1) {
        switch (builder.ops[i]) {
            .begin_switch => nested_depth += 1,
            .end_switch => {
                if (nested_depth == 0) return error.UnexpectedEndSwitchInCase;
                nested_depth -= 1;
            },
            .route => {
                if (nested_depth == 0) return i;
            },
            else => {},
        }
    }

    return switch_end_index;
}

fn makeConfig(comptime builder: anytype) type {
    const total_field_count = builder.tag_len + @as(usize, if (builder.switch_count > 0) 1 else 0);
    var fields: [total_field_count]glib.std.builtin.Type.StructField = undefined;

    inline for (0..builder.tag_len) |i| {
        const tag = builder.tags[i];
        fields[i] = .{
            .name = sentinelName(tag),
            .type = Node,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Node),
        };
    }

    if (builder.switch_count > 0) {
        const BranchStorage = [builder.switch_count]BranchNode;
        const default_branch_storage: BranchStorage = undefined;
        fields[builder.tag_len] = .{
            .name = "__branches",
            .type = BranchStorage,
            .default_value_ptr = @ptrCast(&default_branch_storage),
            .is_comptime = false,
            .alignment = @alignOf(BranchStorage),
        };
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

fn buildSeqRange(
    comptime builder: anytype,
    comptime start: usize,
    comptime end: usize,
    config: anytype,
    next_branch_index: *usize,
    downstream: ?Emitter,
) Node {
    comptime {
        if (start >= end) {
            @compileError("zux.pipeline.NodeBuilder encountered an empty sequence");
        }
    }

    const item_end = comptime nextItemEnd(builder, start, end);
    if (item_end == end) {
        return buildItemRange(builder, start, item_end, config, next_branch_index, downstream);
    }

    const next_root = buildSeqRange(builder, item_end, end, config, next_branch_index, downstream);
    return buildItemRange(builder, start, item_end, config, next_branch_index, next_root.in);
}

fn buildItemRange(
    comptime builder: anytype,
    comptime start: usize,
    comptime end: usize,
    config: anytype,
    next_branch_index: *usize,
    downstream: ?Emitter,
) Node {
    return switch (builder.ops[start]) {
        .node => |tag| blk: {
            comptime {
                if (end != start + 1) {
                    @compileError("zux.pipeline.NodeBuilder node item had an invalid span");
                }
            }
            break :blk buildTag(tag, config, downstream);
        },
        .begin_switch => buildSwitchRange(builder, start, end, config, next_branch_index, downstream),
        .route => @compileError("zux.pipeline.NodeBuilder encountered an unexpected case marker"),
        .end_switch => @compileError("zux.pipeline.NodeBuilder encountered an unexpected switch terminator"),
    };
}

fn buildTag(comptime tag: []const u8, config: anytype, downstream: ?Emitter) Node {
    var node = @field(config.*, tag);
    if (downstream) |out| {
        node.bindOutput(out);
    }
    return node;
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}

fn labelText(comptime raw_label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(raw_label))) {
        .enum_literal => @tagName(raw_label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw_label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => raw_label[0..],
                else => @compileError("zux.pipeline.NodeBuilder label must be enum_literal or []const u8"),
            },
            else => @compileError("zux.pipeline.NodeBuilder label must be enum_literal or []const u8"),
        },
        .array => raw_label[0..],
        else => @compileError("zux.pipeline.NodeBuilder label must be enum_literal or []const u8"),
    };
}

fn sentinelName(comptime text: []const u8) [:0]const u8 {
    const terminated = text ++ "\x00";
    return terminated[0..text.len :0];
}

fn buildSwitchRange(
    comptime builder: anytype,
    comptime start: usize,
    comptime end: usize,
    config: anytype,
    next_branch_index: *usize,
    downstream: ?Emitter,
) Node {
    comptime {
        if (end <= start + 2) {
            @compileError("zux.pipeline.NodeBuilder switch body cannot be empty");
        }
    }

    var routes = BranchNode.emptyRoutes();
    comptime var seen_routes: [route_count]bool = [_]bool{false} ** route_count;
    comptime var i = start + 1;
    comptime var case_count: usize = 0;

    inline while (i < end - 1) {
        const kind = switch (builder.ops[i]) {
            .route => |route_kind| route_kind,
            else => @compileError("zux.pipeline.NodeBuilder switch expected addCase(...) markers"),
        };

        const kind_index = @intFromEnum(kind);
        if (seen_routes[kind_index]) {
            @compileError("zux.pipeline.NodeBuilder switch cannot define the same case twice");
        }
        seen_routes[kind_index] = true;

        const body_start = i + 1;
        const body_end = comptime nextCaseStartOrSwitchEnd(builder, body_start, end - 1);
        comptime {
            if (body_start >= body_end) {
                @compileError("zux.pipeline.NodeBuilder switch case cannot be empty");
            }
        }

        routes[kind_index] = buildSeqRange(
            builder,
            body_start,
            body_end,
            config,
            next_branch_index,
            downstream,
        );
        case_count += 1;
        i = body_end;
    }

    comptime {
        if (case_count == 0) {
            @compileError("zux.pipeline.NodeBuilder switch requires at least one case");
        }
    }

    const branch = &config.__branches[next_branch_index.*];
    next_branch_index.* += 1;
    return branch.init(routes);
}

fn nextItemEnd(comptime builder: anytype, comptime start: usize, comptime limit: usize) usize {
    comptime {
        if (start >= limit) {
            @compileError("zux.pipeline.NodeBuilder tried to parse beyond the end of the op stream");
        }
    }

    return switch (builder.ops[start]) {
        .node => start + 1,
        .begin_switch => findMatchingSwitchEnd(builder, start, limit),
        .route => @compileError("zux.pipeline.NodeBuilder sequence cannot start with addCase(...)"),
        .end_switch => @compileError("zux.pipeline.NodeBuilder sequence cannot start with endSwitch()"),
    };
}

fn findMatchingSwitchEnd(comptime builder: anytype, comptime start: usize, comptime limit: usize) usize {
    comptime var depth: usize = 1;
    comptime var i = start + 1;

    inline while (i < limit) : (i += 1) {
        switch (builder.ops[i]) {
            .begin_switch => depth += 1,
            .end_switch => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }

    @compileError("zux.pipeline.NodeBuilder found an unterminated switch while parsing");
}

fn nextCaseStartOrSwitchEnd(comptime builder: anytype, comptime start: usize, comptime switch_end_index: usize) usize {
    comptime var nested_depth: usize = 0;
    comptime var i = start;

    inline while (i < switch_end_index) : (i += 1) {
        switch (builder.ops[i]) {
            .begin_switch => nested_depth += 1,
            .end_switch => {
                if (nested_depth == 0) {
                    @compileError("zux.pipeline.NodeBuilder saw an unexpected endSwitch() inside a case body");
                }
                nested_depth -= 1;
            },
            .route => {
                if (nested_depth == 0) return i;
            },
            else => {},
        }
    }

    return switch_end_index;
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn buildReturnsRootNode(testing: anytype) !void {
            const Built = comptime blk: {
                var builder = Builder(.{ .max_ops = 16 }).init();
                builder.addNode(.a);
                builder.beginSwitch();
                builder.addCase(.button_gesture);
                builder.addNode(.b);
                builder.addNode(.c);
                builder.addCase(.raw_single_button);
                builder.addNode(.d);
                builder.endSwitch();
                builder.addNode(.e);
                break :blk builder.make();
            };

            const Forward = struct {
                out: ?Emitter = null,
                called: usize = 0,
                delta_ns: i128,

                pub fn bindOutput(self: *@This(), out: Emitter) void {
                    self.out = out;
                }

                pub fn process(self: *@This(), message: Message) !usize {
                    self.called += 1;
                    var next = message;
                    next.timestamp_ns += self.delta_ns;
                    if (self.out) |out| {
                        try out.emit(next);
                    }
                    return 1;
                }
            };

            const Collector = struct {
                count: usize = 0,
                last_timestamp_ns: i128 = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.count += 1;
                    self.last_timestamp_ns = message.timestamp_ns;
                }
            };

            var a_impl = Forward{ .delta_ns = 1 };
            var b_impl = Forward{ .delta_ns = 2 };
            var c_impl = Forward{ .delta_ns = 4 };
            var d_impl = Forward{ .delta_ns = 8 };
            var e_impl = Forward{ .delta_ns = 16 };
            var collector = Collector{};

            var config: Built.Config = .{
                .a = Node.init(Forward, &a_impl),
                .b = Node.init(Forward, &b_impl),
                .c = Node.init(Forward, &c_impl),
                .d = Node.init(Forward, &d_impl),
                .e = Node.init(Forward, &e_impl),
            };

            var root = Built.build(&config);
            config.e.bindOutput(Emitter.init(&collector));

            const emitted_button = try root.process(.{
                .origin = .source,
                .timestamp_ns = 10,
                .body = .{
                    .button_gesture = .{
                        .source_id = 1,
                        .gesture = .{ .click = 1 },
                    },
                },
            });
            try testing.expectEqual(@as(usize, 1), emitted_button);
            try testing.expectEqual(@as(usize, 1), a_impl.called);
            try testing.expectEqual(@as(usize, 1), b_impl.called);
            try testing.expectEqual(@as(usize, 1), c_impl.called);
            try testing.expectEqual(@as(usize, 0), d_impl.called);
            try testing.expectEqual(@as(usize, 1), e_impl.called);
            try testing.expectEqual(@as(i128, 33), collector.last_timestamp_ns);

            const emitted_raw = try root.process(.{
                .origin = .source,
                .timestamp_ns = 15,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = true,
                    },
                },
            });
            try testing.expectEqual(@as(usize, 1), emitted_raw);
            try testing.expectEqual(@as(usize, 2), a_impl.called);
            try testing.expectEqual(@as(usize, 1), b_impl.called);
            try testing.expectEqual(@as(usize, 1), c_impl.called);
            try testing.expectEqual(@as(usize, 1), d_impl.called);
            try testing.expectEqual(@as(usize, 2), e_impl.called);
            try testing.expectEqual(@as(i128, 40), collector.last_timestamp_ns);

            const emitted_tick = try root.process(.{
                .origin = .timer,
                .timestamp_ns = 20,
                .body = .{
                    .tick = .{},
                },
            });
            try testing.expectEqual(@as(usize, 1), emitted_tick);
            try testing.expectEqual(@as(usize, 3), a_impl.called);
            try testing.expectEqual(@as(usize, 2), b_impl.called);
            try testing.expectEqual(@as(usize, 2), c_impl.called);
            try testing.expectEqual(@as(usize, 2), d_impl.called);
            try testing.expectEqual(@as(usize, 4), e_impl.called);
            try testing.expectEqual(@as(i128, 43), collector.last_timestamp_ns);
            try testing.expectEqual(@as(usize, 4), collector.count);
        }

        fn buildAllowsEmptyBuilder(testing: anytype) !void {
            const Built = comptime blk: {
                const builder = Builder(.{}).init();
                break :blk builder.make();
            };

            const Collector = struct {
                called: bool = false,
                last_kind: ?Message.Kind = null,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.called = true;
                    self.last_kind = message.kind();
                }
            };

            var config: Built.Config = .{};
            var root = Built.build(&config);
            var collector = Collector{};
            root.bindOutput(Emitter.init(&collector));

            const emitted = try root.process(.{
                .origin = .manual,
                .body = .{
                    .tick = .{},
                },
            });

            try testing.expectEqual(@as(usize, 1), emitted);
            try testing.expect(collector.called);
            try testing.expectEqual(Message.Kind.tick, collector.last_kind.?);
        }

        fn validateRejectsUnterminatedSwitch(testing: anytype) !void {
            const result = comptime blk: {
                var builder = Builder(.{}).init();
                builder.beginSwitch();
                builder.addCase(.button_gesture);
                builder.addNode(.a);
                break :blk builder.validate();
            };

            try testing.expectError(error.UnterminatedSwitch, result);
        }

        fn validateRejectsDuplicateCase(testing: anytype) !void {
            const result = comptime blk: {
                var builder = Builder(.{}).init();
                builder.beginSwitch();
                builder.addCase(.button_gesture);
                builder.addNode(.a);
                builder.addCase(.button_gesture);
                builder.addNode(.b);
                builder.endSwitch();
                break :blk builder.validate();
            };

            try testing.expectError(error.DuplicateCase, result);
        }

        fn buildHandlesNestedSwitches(testing: anytype) !void {
            const Built = comptime blk: {
                var builder = Builder(.{}).init();
                builder.addNode(.a);
                builder.beginSwitch();
                builder.addCase(.button_gesture);
                builder.beginSwitch();
                builder.addCase(.button_gesture);
                builder.addNode(.b);
                builder.endSwitch();
                builder.addCase(.raw_single_button);
                builder.addNode(.d);
                builder.endSwitch();
                builder.addNode(.e);
                break :blk builder.make();
            };

            const Trace = struct {
                ids: [8]u8 = undefined,
                len: usize = 0,

                pub fn reset(self: *@This()) void {
                    self.len = 0;
                }

                pub fn append(self: *@This(), id: u8) void {
                    self.ids[self.len] = id;
                    self.len += 1;
                }
            };

            const Forward = struct {
                out: ?Emitter = null,
                id: u8,
                trace: *Trace,

                pub fn bindOutput(self: *@This(), out: Emitter) void {
                    self.out = out;
                }

                pub fn process(self: *@This(), message: Message) !usize {
                    self.trace.append(self.id);
                    if (self.out) |out| {
                        try out.emit(message);
                    }
                    return 1;
                }
            };

            var trace = Trace{};
            var a_impl = Forward{ .id = 1, .trace = &trace };
            var b_impl = Forward{ .id = 2, .trace = &trace };
            var d_impl = Forward{ .id = 4, .trace = &trace };
            var e_impl = Forward{ .id = 5, .trace = &trace };

            var config: Built.Config = .{
                .a = Node.init(Forward, &a_impl),
                .b = Node.init(Forward, &b_impl),
                .d = Node.init(Forward, &d_impl),
                .e = Node.init(Forward, &e_impl),
            };

            var root = Built.build(&config);

            trace.reset();
            _ = try root.process(.{
                .origin = .source,
                .body = .{
                    .button_gesture = .{
                        .source_id = 1,
                        .gesture = .{ .click = 1 },
                    },
                },
            });
            try testing.expectEqual(@as(usize, 3), trace.len);
            try testing.expectEqual(@as(u8, 1), trace.ids[0]);
            try testing.expectEqual(@as(u8, 2), trace.ids[1]);
            try testing.expectEqual(@as(u8, 5), trace.ids[2]);

            trace.reset();
            _ = try root.process(.{
                .origin = .source,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = true,
                    },
                },
            });
            try testing.expectEqual(@as(usize, 3), trace.len);
            try testing.expectEqual(@as(u8, 1), trace.ids[0]);
            try testing.expectEqual(@as(u8, 4), trace.ids[1]);
            try testing.expectEqual(@as(u8, 5), trace.ids[2]);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            inline for (.{
                TestCase.buildReturnsRootNode,
                TestCase.buildAllowsEmptyBuilder,
                TestCase.validateRejectsUnterminatedSwitch,
                TestCase.validateRejectsDuplicateCase,
                TestCase.buildHandlesNestedSwitches,
            }) |case| {
                case(testing) catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
