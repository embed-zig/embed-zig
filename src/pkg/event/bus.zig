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

// Integration tests live in bus_integration_test.zig (separate module root
// so it can import both event and source/button packages).
pub const test_exports = blk: {
    const __test_export_0 = types;
    const __test_export_1 = mw_mod;
    const __test_export_2 = runtime;
    break :blk struct {
        pub const types = __test_export_0;
        pub const mw_mod = __test_export_1;
        pub const runtime = __test_export_2;
    };
};
