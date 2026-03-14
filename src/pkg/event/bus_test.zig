const std = @import("std");
const module = @import("bus.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const fd_t = module.fd_t;
const Periph = module.Periph;
const Bus = module.Bus;
const types = test_exports.types;
const mw_mod = test_exports.mw_mod;
const runtime = test_exports.runtime;

// ---------------------------------------------------------------------------
// Tests — real runtime.std.IO, user-defined TestEvent
// ---------------------------------------------------------------------------

const testing = std.testing;
const StdIO = runtime.std.IO;

const TestEvent = union(enum) {
    button: types.PeriphEvent,
    system: types.SystemEvent,
};

const TestBus = Bus(StdIO, TestEvent);
const TestPeriphType = Periph(TestEvent);

const WireCode = extern struct { code: u16 };

const PipePeripheral = struct {
    pipe_r: fd_t,
    pipe_w: fd_t,
    id: []const u8,
    periph: TestPeriphType,

    fn open(id: []const u8) !PipePeripheral {
        const fds = try std.posix.pipe();
        try setNonBlocking(fds[0]);
        try setNonBlocking(fds[1]);
        return .{
            .pipe_r = fds[0],
            .pipe_w = fds[1],
            .id = id,
            .periph = undefined,
        };
    }

    fn bind(self: *PipePeripheral) void {
        self.periph = .{ .ctx = self, .fd = self.pipe_r, .onReady = onReady };
    }

    fn close(self: *PipePeripheral) void {
        std.posix.close(self.pipe_r);
        std.posix.close(self.pipe_w);
    }

    fn send(self: *PipePeripheral, code: u16) void {
        const wire = WireCode{ .code = code };
        _ = std.posix.write(self.pipe_w, std.mem.asBytes(&wire)) catch {};
    }

    fn onReady(ctx: ?*anyopaque, _: fd_t, buf: *std.ArrayList(TestEvent), alloc: std.mem.Allocator) void {
        const self: *PipePeripheral = @ptrCast(@alignCast(ctx orelse return));
        var wire: WireCode = undefined;
        const wire_bytes = std.mem.asBytes(&wire);
        while (true) {
            const n = std.posix.read(self.pipe_r, wire_bytes) catch break;
            if (n < wire_bytes.len) break;
            buf.append(alloc, .{
                .button = .{ .id = self.id, .code = wire.code, .data = 0 },
            }) catch {};
        }
    }

    fn setNonBlocking(fd: fd_t) !void {
        var fl = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        const mask: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
        fl |= mask;
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, fl);
    }
};

test "register peripheral and collect events via poll" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = TestBus.init(testing.allocator, &io);
    defer bus.deinit();

    var p = try PipePeripheral.open("btn.a");
    defer p.close();
    p.bind();
    try bus.register(&p.periph);

    p.send(10);
    p.send(11);

    var out: [8]TestEvent = undefined;
    const got = bus.poll(&out, 200);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("btn.a", got[0].button.id);
    try testing.expectEqual(@as(u16, 10), got[0].button.code);
    try testing.expectEqual(@as(u16, 11), got[1].button.code);
}

test "multiple peripherals on same bus" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = TestBus.init(testing.allocator, &io);
    defer bus.deinit();

    var btn = try PipePeripheral.open("btn.a");
    defer btn.close();
    btn.bind();
    var sensor = try PipePeripheral.open("sensor.0");
    defer sensor.close();
    sensor.bind();

    try bus.register(&btn.periph);
    try bus.register(&sensor.periph);

    btn.send(1);
    sensor.send(2);

    var out: [8]TestEvent = undefined;
    const got = bus.poll(&out, 200);
    try testing.expectEqual(@as(usize, 2), got.len);
}

test "unregister removes peripheral from poll" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = TestBus.init(testing.allocator, &io);
    defer bus.deinit();

    var p = try PipePeripheral.open("btn.x");
    defer p.close();
    p.bind();
    try bus.register(&p.periph);

    bus.unregister(p.pipe_r);

    p.send(99);
    io.wake();

    var out: [4]TestEvent = undefined;
    const got = bus.poll(&out, 50);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "poll with no ready events returns empty" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = TestBus.init(testing.allocator, &io);
    defer bus.deinit();

    var out: [4]TestEvent = undefined;
    const got = bus.poll(&out, 0);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "middleware transforms events" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = TestBus.init(testing.allocator, &io);
    defer bus.deinit();

    const DoubleCode = struct {
        fn process(_: ?*anyopaque, ev: TestEvent, emit_ctx: *anyopaque, emit: mw_mod.EmitFn(TestEvent)) void {
            switch (ev) {
                .button => |b| emit(emit_ctx, .{
                    .button = .{ .id = b.id, .code = b.code * 2, .data = b.data },
                }),
                else => emit(emit_ctx, ev),
            }
        }
    };

    bus.use(.{ .ctx = null, .processFn = DoubleCode.process, .tickFn = null });

    var p = try PipePeripheral.open("btn.m");
    defer p.close();
    p.bind();
    try bus.register(&p.periph);

    p.send(5);

    var out: [4]TestEvent = undefined;
    const got = bus.poll(&out, 200);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u16, 10), got[0].button.code);
}

test "middleware can swallow events" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = TestBus.init(testing.allocator, &io);
    defer bus.deinit();

    const DropAll = struct {
        fn process(_: ?*anyopaque, _: TestEvent, _: *anyopaque, _: mw_mod.EmitFn(TestEvent)) void {}
    };

    bus.use(.{ .ctx = null, .processFn = DropAll.process, .tickFn = null });

    var p = try PipePeripheral.open("btn.d");
    defer p.close();
    p.bind();
    try bus.register(&p.periph);

    p.send(1);
    io.wake();

    var out: [4]TestEvent = undefined;
    const got = bus.poll(&out, 100);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "non-button events pass through middleware" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = TestBus.init(testing.allocator, &io);
    defer bus.deinit();

    const ButtonOnly = struct {
        fn process(_: ?*anyopaque, ev: TestEvent, emit_ctx: *anyopaque, emit: mw_mod.EmitFn(TestEvent)) void {
            switch (ev) {
                .button => {},
                else => emit(emit_ctx, ev),
            }
        }
    };

    bus.use(.{ .ctx = null, .processFn = ButtonOnly.process, .tickFn = null });

    bus.ready.append(testing.allocator, .{ .system = .ready }) catch {};

    var out: [4]TestEvent = undefined;
    const got = bus.poll(&out, 0);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(TestEvent{ .system = .ready }, got[0]);
}
