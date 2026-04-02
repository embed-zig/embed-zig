const Emitter = @import("Emitter.zig");
const Message = @import("Message.zig");

const Node = @This();

impl: *anyopaque,
in: Emitter,
out: ?Emitter = null,
vtable: *const VTable,
type_id: *const anyopaque,

fn TypeIdHolder(comptime T: type) type {
    return struct {
        comptime _phantom: type = T,
        var id: u8 = 0;
    };
}

fn typeId(comptime T: type) *const anyopaque {
    return @ptrCast(&TypeIdHolder(T).id);
}

pub const VTable = struct {
    process: *const fn (node: *Node, message: Message) anyerror!usize,
    bindOutput: ?*const fn (node: *Node, out: Emitter) void = null,
};

pub fn as(self: Node, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.impl));
    return error.TypeMismatch;
}

pub fn process(self: *Node, message: Message) !usize {
    return self.vtable.process(self, message);
}

pub fn emit(self: *Node, message: Message) !void {
    _ = try self.process(message);
}

pub fn bindOutput(self: *Node, out: Emitter) void {
    self.out = out;
    if (self.vtable.bindOutput) |bindOutputFn| {
        bindOutputFn(self, out);
    }
}

pub fn init(comptime T: type, impl: *T) Node {
    comptime {
        _ = @as(*const fn (*T, Message) anyerror!usize, &T.process);
        if (@hasDecl(T, "bindOutput")) {
            _ = @as(*const fn (*T, Emitter) void, &T.bindOutput);
        }
    }

    const gen = struct {
        const has_bindOutput = @hasDecl(T, "bindOutput");

        fn processImpl(ctx: *anyopaque, message: Message) anyerror!usize {
            const self: *T = @ptrCast(@alignCast(ctx));
            return self.process(message);
        }

        fn emitNode(ctx: *anyopaque, message: Message) anyerror!void {
            _ = try processImpl(ctx, message);
        }

        fn processFn(node: *Node, message: Message) anyerror!usize {
            return processImpl(node.impl, message);
        }

        const emitter_vtable = Emitter.VTable{
            .emit = emitNode,
        };

        const bindOutputFn = if (has_bindOutput)
            struct {
                fn bindOutputFn(node: *Node, out: Emitter) void {
                    const self: *T = @ptrCast(@alignCast(node.impl));
                    self.bindOutput(out);
                }
            }.bindOutputFn
        else
            null;

        const vtable = VTable{
            .process = processFn,
            .bindOutput = bindOutputFn,
        };
    };

    var node: Node = .{
        .impl = @ptrCast(impl),
        .in = undefined,
        .out = null,
        .vtable = &gen.vtable,
        .type_id = typeId(T),
    };
    node.in = .{
        .ctx = @ptrCast(impl),
        .vtable = &gen.emitter_vtable,
    };
    return node;
}

test "zux/pipeline/Node/unit_tests/init_bind_and_process" {
    const std = @import("std");

    const Impl = struct {
        called: bool = false,

        pub fn process(self: *@This(), _: Message) !usize {
            self.called = true;
            return 1;
        }
    };

    var impl = Impl{};

    var node = Node.init(Impl, &impl);
    try std.testing.expect((try node.as(Impl)) == &impl);
    try std.testing.expectError(error.TypeMismatch, node.as(struct { x: u8 }));
    const emitted = try node.process(.{
        .origin = .source,
        .body = .{
            .raw_single_button = .{
                .source_id = 1,
                .pressed = true,
            },
        },
    });

    try std.testing.expect(impl.called);
    try std.testing.expectEqual(@as(usize, 1), emitted);
}

test "zux/pipeline/Node/unit_tests/cascade_through_bound_outputs" {
    const std = @import("std");

    const Forward = struct {
        out: ?Emitter = null,
        called: bool = false,
        delta_ns: i128,

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !usize {
            self.called = true;
            var next = message;
            next.timestamp_ns += self.delta_ns;
            try self.out.?.emit(next);
            return 1;
        }
    };

    const Collector = struct {
        called: bool = false,
        last_timestamp_ns: i128 = 0,

        pub fn emit(self: *@This(), message: Message) !void {
            self.called = true;
            self.last_timestamp_ns = message.timestamp_ns;
        }
    };

    var first_impl = Forward{ .delta_ns = 2 };
    var second_impl = Forward{ .delta_ns = 3 };
    var collector = Collector{};

    var first = Node.init(Forward, &first_impl);
    var second = Node.init(Forward, &second_impl);

    first.bindOutput(Emitter.init(&second));
    second.bindOutput(Emitter.init(&collector));

    const emitted = try first.process(.{
        .origin = .source,
        .timestamp_ns = 5,
        .body = .{
            .raw_single_button = .{
                .source_id = 1,
                .pressed = true,
            },
        },
    });

    try std.testing.expect(first_impl.called);
    try std.testing.expect(second_impl.called);
    try std.testing.expect(collector.called);
    try std.testing.expectEqual(@as(i128, 10), collector.last_timestamp_ns);
    try std.testing.expectEqual(@as(usize, 1), emitted);
}
