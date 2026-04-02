const builtin = @import("std").builtin;
const BranchNode = @import("BranchNode.zig");
const Emitter = @import("Emitter.zig");
const Message = @import("Message.zig");
const Node = @import("Node.zig");

pub fn make(comptime spec: anytype) type {
    return struct {
        pub const Spec = spec;
        pub const Config = makeConfig(spec);

        pub fn build(config: *Config) Node {
            var next_branch_index: usize = 0;
            return buildSpec(spec, config, &next_branch_index, null);
        }
    };
}

fn makeConfig(comptime spec: anytype) type {
    const tag_count = uniqueTagCount(spec);
    const switch_count = countSwitches(spec);

    comptime var tags: [tag_count]@Type(.enum_literal) = undefined;
    comptime var len: usize = 0;
    collectTagRefs(spec, &tags, &len);

    const total_field_count = tag_count + @as(usize, if (switch_count > 0) 1 else 0);
    var fields: [total_field_count]builtin.Type.StructField = undefined;

    inline for (tags, 0..) |tag, i| {
        fields[i] = .{
            .name = @tagName(tag),
            .type = Node,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Node),
        };
    }

    if (switch_count > 0) {
        const BranchStorage = [switch_count]BranchNode;
        const default_branch_storage: BranchStorage = undefined;
        fields[tag_count] = .{
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

fn buildSpec(
    comptime spec: anytype,
    config: anytype,
    next_branch_index: *usize,
    downstream: ?Emitter,
) Node {
    return switch (@typeInfo(@TypeOf(spec))) {
        .@"enum_literal" => buildTag(spec, config, downstream),
        .pointer => |info| blk: {
            if (info.size != .one) {
                @compileError("zux.pipeline.NodeBuilder.make expects single-item comptime pointers");
            }
            break :blk buildSpec(spec.*, config, next_branch_index, downstream);
        },
        .array => buildSeq(spec, spec.len, config, next_branch_index, downstream),
        .@"struct" => |info| blk: {
            if (info.is_tuple) {
                break :blk buildSeq(spec, info.fields.len, config, next_branch_index, downstream);
            }
            break :blk buildSwitch(spec, info.fields, config, next_branch_index, downstream);
        },
        else => @compileError("zux.pipeline.NodeBuilder.make expects tag literals, tuples, arrays, or switch structs"),
    };
}

fn buildTag(comptime tag: @Type(.enum_literal), config: anytype, downstream: ?Emitter) Node {
    var node = @field(config.*, @tagName(tag));
    if (downstream) |out| {
        node.bindOutput(out);
    }
    return node;
}

fn buildSeq(
    comptime spec: anytype,
    comptime len: usize,
    config: anytype,
    next_branch_index: *usize,
    downstream: ?Emitter,
) Node {
    if (len == 0) {
        @compileError("zux.pipeline.NodeBuilder.make does not support empty seq specs");
    }

    var next_root: ?Node = null;
    comptime var i = len;
    inline while (i > 0) {
        i -= 1;
        const out = if (next_root) |root| root.in else downstream;
        next_root = buildSpec(spec[i], config, next_branch_index, out);
    }

    return next_root.?;
}

fn buildSwitch(
    comptime switch_spec: anytype,
    comptime fields: []const builtin.Type.StructField,
    config: anytype,
    next_branch_index: *usize,
    downstream: ?Emitter,
) Node {
    var routes = BranchNode.emptyRoutes();
    inline for (fields) |field| {
        const kind = @field(Message.Kind, field.name);
        routes[@intFromEnum(kind)] = buildSpec(
            @field(switch_spec, field.name),
            config,
            next_branch_index,
            downstream,
        );
    }

    const branch = &config.__branches[next_branch_index.*];
    next_branch_index.* += 1;
    return branch.init(routes);
}

fn uniqueTagCount(comptime spec: anytype) usize {
    const max_tag_count = countTagRefs(spec);
    comptime var tags: [max_tag_count]@Type(.enum_literal) = undefined;
    comptime var len: usize = 0;
    collectTagRefs(spec, &tags, &len);
    return len;
}

fn countTagRefs(comptime spec: anytype) usize {
    return switch (@typeInfo(@TypeOf(spec))) {
        .@"enum_literal" => 1,
        .pointer => |info| blk: {
            if (info.size != .one) {
                @compileError("zux.pipeline.NodeBuilder.make expects single-item comptime pointers");
            }
            break :blk countTagRefs(spec.*);
        },
        .array => blk: {
            comptime var count: usize = 0;
            inline for (spec) |item| {
                count += countTagRefs(item);
            }
            break :blk count;
        },
        .@"struct" => |info| blk: {
            comptime var count: usize = 0;
            if (info.is_tuple) {
                inline for (spec) |item| {
                    count += countTagRefs(item);
                }
            } else {
                inline for (info.fields) |field| {
                    count += countTagRefs(@field(spec, field.name));
                }
            }
            break :blk count;
        },
        else => @compileError("zux.pipeline.NodeBuilder.make expects tag literals, tuples, arrays, or switch structs"),
    };
}

fn countSwitches(comptime spec: anytype) usize {
    return switch (@typeInfo(@TypeOf(spec))) {
        .@"enum_literal" => 0,
        .pointer => |info| blk: {
            if (info.size != .one) {
                @compileError("zux.pipeline.NodeBuilder.make expects single-item comptime pointers");
            }
            break :blk countSwitches(spec.*);
        },
        .array => blk: {
            comptime var count: usize = 0;
            inline for (spec) |item| {
                count += countSwitches(item);
            }
            break :blk count;
        },
        .@"struct" => |info| blk: {
            comptime var count: usize = if (info.is_tuple) 0 else 1;
            if (info.is_tuple) {
                inline for (spec) |item| {
                    count += countSwitches(item);
                }
            } else {
                inline for (info.fields) |field| {
                    count += countSwitches(@field(spec, field.name));
                }
            }
            break :blk count;
        },
        else => @compileError("zux.pipeline.NodeBuilder.make expects tag literals, tuples, arrays, or switch structs"),
    };
}

fn collectTagRefs(comptime spec: anytype, comptime tags: anytype, comptime len: *usize) void {
    switch (@typeInfo(@TypeOf(spec))) {
        .@"enum_literal" => appendUniqueTag(spec, tags, len),
        .pointer => |info| {
            if (info.size != .one) {
                @compileError("zux.pipeline.NodeBuilder.make expects single-item comptime pointers");
            }
            collectTagRefs(spec.*, tags, len);
        },
        .array => {
            inline for (spec) |item| {
                collectTagRefs(item, tags, len);
            }
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                inline for (spec) |item| {
                    collectTagRefs(item, tags, len);
                }
            } else {
                inline for (info.fields) |field| {
                    collectTagRefs(@field(spec, field.name), tags, len);
                }
            }
        },
        else => @compileError("zux.pipeline.NodeBuilder.make expects tag literals, tuples, arrays, or switch structs"),
    }
}

fn appendUniqueTag(
    comptime tag: @Type(.enum_literal),
    comptime tags: anytype,
    comptime len: *usize,
) void {
    inline for (0..len.*) |i| {
        if (tags.*[i] == tag) return;
    }

    tags.*[len.*] = tag;
    len.* += 1;
}

test "zux/pipeline/NodeBuilder/unit_tests/build_returns_root_node" {
    const std = @import("std");

    const Builder = make(&.{
        .a,
        .{
            .button_gesture = .{ .b, .c },
            .raw_single_button = .{ .d },
        },
        .e,
    });

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

    var config: Builder.Config = .{
        .a = Node.init(Forward, &a_impl),
        .b = Node.init(Forward, &b_impl),
        .c = Node.init(Forward, &c_impl),
        .d = Node.init(Forward, &d_impl),
        .e = Node.init(Forward, &e_impl),
    };

    var root = Builder.build(&config);
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
    try std.testing.expectEqual(@as(usize, 1), emitted_button);
    try std.testing.expectEqual(@as(usize, 1), a_impl.called);
    try std.testing.expectEqual(@as(usize, 1), b_impl.called);
    try std.testing.expectEqual(@as(usize, 1), c_impl.called);
    try std.testing.expectEqual(@as(usize, 0), d_impl.called);
    try std.testing.expectEqual(@as(usize, 1), e_impl.called);
    try std.testing.expectEqual(@as(i128, 33), collector.last_timestamp_ns);

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
    try std.testing.expectEqual(@as(usize, 1), emitted_raw);
    try std.testing.expectEqual(@as(usize, 2), a_impl.called);
    try std.testing.expectEqual(@as(usize, 1), b_impl.called);
    try std.testing.expectEqual(@as(usize, 1), c_impl.called);
    try std.testing.expectEqual(@as(usize, 1), d_impl.called);
    try std.testing.expectEqual(@as(usize, 2), e_impl.called);
    try std.testing.expectEqual(@as(i128, 40), collector.last_timestamp_ns);

    const emitted_tick = try root.process(.{
        .origin = .timer,
        .timestamp_ns = 20,
        .body = .{
            .tick = .{},
        },
    });
    try std.testing.expectEqual(@as(usize, 1), emitted_tick);
    try std.testing.expectEqual(@as(usize, 3), a_impl.called);
    try std.testing.expectEqual(@as(usize, 2), b_impl.called);
    try std.testing.expectEqual(@as(usize, 2), c_impl.called);
    try std.testing.expectEqual(@as(usize, 2), d_impl.called);
    try std.testing.expectEqual(@as(usize, 4), e_impl.called);
    try std.testing.expectEqual(@as(i128, 43), collector.last_timestamp_ns);
    try std.testing.expectEqual(@as(usize, 4), collector.count);
}
