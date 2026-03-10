//! IO-driven event bus, generic over EventType.
//!
//! EventType must be a `union(enum)`. Each peripheral and middleware is
//! parameterized on the same EventType so the whole pipeline is type-safe
//! at comptime.
//!
//! Flow:
//!   peripheral worker → write to its fd
//!   bus.poll()        → io.poll(timeout) blocks
//!                     → io fires ReadyCallback → Periph.onReady → appends to bus ready buffer
//!                     → events pass through middleware chain
//!                     → bus.poll returns processed events

const std = @import("std");
const types = @import("types.zig");
const mw_mod = @import("middleware.zig");
const runtime = struct {
    pub const io = @import("../../runtime/io.zig");
    pub const std = @import("../../runtime/std.zig");
};

pub const fd_t = runtime.io.fd_t;

/// Type-erased peripheral handle, generic over EventType.
pub fn Periph(comptime EventType: type) type {
    comptime types.assertTaggedUnion(EventType);
    return struct {
        ctx: ?*anyopaque,
        fd: fd_t,
        onReady: *const fn (ctx: ?*anyopaque, fd: fd_t, buf: *std.ArrayList(EventType), alloc: std.mem.Allocator) void,
    };
}

pub fn Bus(comptime IO: type, comptime EventType: type) type {
    comptime {
        _ = runtime.io.from(IO);
        types.assertTaggedUnion(EventType);
    }

    const PeriphType = Periph(EventType);
    const MiddlewareType = mw_mod.Middleware(EventType);

    return struct {
        const Self = @This();

        pub const Event = EventType;
        pub const Mw = MiddlewareType;

        const Binding = struct {
            periph: *const PeriphType,
            bus: *Self,
        };

        allocator: std.mem.Allocator,
        io: *IO,
        ready: std.ArrayList(EventType),
        bindings: std.ArrayList(*Binding),
        middlewares: std.ArrayList(MiddlewareType),
        processed: std.ArrayList(EventType),

        pub fn init(allocator: std.mem.Allocator, io: *IO) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .ready = .empty,
                .bindings = .empty,
                .middlewares = .empty,
                .processed = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.bindings.items) |b| {
                self.io.unregister(b.periph.fd);
                self.allocator.destroy(b);
            }
            self.bindings.deinit(self.allocator);
            self.ready.deinit(self.allocator);
            self.middlewares.deinit(self.allocator);
            self.processed.deinit(self.allocator);
        }

        pub fn use(self: *Self, middleware: MiddlewareType) void {
            self.middlewares.append(self.allocator, middleware) catch {};
        }

        pub fn register(self: *Self, periph: *const PeriphType) !void {
            const binding = try self.allocator.create(Binding);
            binding.* = .{ .periph = periph, .bus = self };

            errdefer self.allocator.destroy(binding);

            try self.io.registerRead(periph.fd, .{
                .ptr = binding,
                .callback = dispatchReady,
            });

            try self.bindings.append(self.allocator, binding);
        }

        pub fn unregister(self: *Self, periph_fd: fd_t) void {
            self.io.unregister(periph_fd);
            for (self.bindings.items, 0..) |b, i| {
                if (b.periph.fd == periph_fd) {
                    self.allocator.destroy(b);
                    _ = self.bindings.swapRemove(i);
                    return;
                }
            }
        }

        pub fn poll(self: *Self, out: []EventType, timeout_ms: i32) []EventType {
            if (self.ready.items.len == 0 and self.processed.items.len == 0) {
                _ = self.io.poll(timeout_ms);
            }
            self.applyMiddlewares();
            return self.drain(out);
        }

        pub fn wake(self: *Self) void {
            self.io.wake();
        }

        fn applyMiddlewares(self: *Self) void {
            if (self.middlewares.items.len == 0) {
                for (self.ready.items) |ev| {
                    self.processed.append(self.allocator, ev) catch {};
                }
                self.ready.items.len = 0;
                return;
            }

            for (self.ready.items) |ev| {
                self.runChain(ev, 0);
            }
            self.ready.items.len = 0;

            for (self.middlewares.items, 0..) |middleware, i| {
                if (middleware.tickFn) |tick| {
                    var ctx = ChainCtx{ .bus = self, .next_idx = i + 1 };
                    tick(middleware.ctx, 0, @ptrCast(&ctx), chainEmit);
                }
            }
        }

        fn runChain(self: *Self, ev: EventType, idx: usize) void {
            if (idx >= self.middlewares.items.len) {
                self.processed.append(self.allocator, ev) catch {};
                return;
            }

            const mw = self.middlewares.items[idx];
            var ctx = ChainCtx{ .bus = self, .next_idx = idx + 1 };
            if (mw.processFn) |processFn| {
                processFn(mw.ctx, ev, @ptrCast(&ctx), chainEmit);
            } else {
                chainEmit(@ptrCast(&ctx), ev);
            }
        }

        const ChainCtx = struct {
            bus: *Self,
            next_idx: usize,
        };

        fn chainEmit(raw: *anyopaque, ev: EventType) void {
            const ctx: *ChainCtx = @ptrCast(@alignCast(raw));
            ctx.bus.runChain(ev, ctx.next_idx);
        }

        fn drain(self: *Self, out: []EventType) []EventType {
            const src = &self.processed;
            const n = @min(src.items.len, out.len);
            if (n == 0) return out[0..0];
            @memcpy(out[0..n], src.items[0..n]);
            const remain = src.items.len - n;
            if (remain > 0) {
                std.mem.copyForwards(EventType, src.items[0..remain], src.items[n..]);
            }
            src.items.len = remain;
            return out[0..n];
        }

        fn dispatchReady(raw: ?*anyopaque, ready_fd: fd_t) void {
            const binding: *const Binding = @ptrCast(@alignCast(raw orelse return));
            binding.periph.onReady(binding.periph.ctx, ready_fd, &binding.bus.ready, binding.bus.allocator);
        }
    };
}

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

// Integration tests live in bus_integration_test.zig (separate module root
// so it can import both event and source/button packages).
