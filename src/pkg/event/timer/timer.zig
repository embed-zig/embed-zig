//! Timer event source — emits periodic or one-shot timer events via a pipe fd
//! that the event bus can multiplex.
//!
//! Generic over EventType and tag. The EventType's tag payload must be a
//! struct with at least `id: []const u8` and `count: u32` fields.

const std = @import("std");
const runtime = struct {
    pub const io = @import("../../../runtime/io.zig");
};
const event_pkg = struct {
    pub const types = @import("../types.zig");

    pub fn Periph(comptime EventType: type) type {
        return @import("../bus.zig").Periph(EventType);
    }
};

pub const Mode = enum {
    one_shot,
    repeating,
};

pub const Config = struct {
    id: []const u8 = "timer",
    interval_ms: u32 = 1000,
    mode: Mode = .repeating,
    thread_stack_size: usize = 4096,
};

pub const TimerPayload = struct {
    id: []const u8,
    count: u32,
    interval_ms: u32,
};

pub fn TimerSource(
    comptime Thread: type,
    comptime Time: type,
    comptime IO: type,
    comptime EventType: type,
    comptime tag: []const u8,
) type {
    comptime {
        _ = runtime.io.from(IO);
        event_pkg.types.assertTaggedUnion(EventType);
    }

    const fd_t = runtime.io.fd_t;
    const PeriphType = event_pkg.Periph(EventType);

    return struct {
        const Self = @This();

        periph: PeriphType,
        io: *IO,
        time: Time,
        config: Config,
        worker: ?Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pipe_r: fd_t,
        pipe_w: fd_t,

        const WireEvent = extern struct {
            count: u32,
        };

        pub fn init(io: *IO, time: Time, config: Config) !Self {
            const pipe_fds = try std.posix.pipe();
            errdefer {
                std.posix.close(pipe_fds[0]);
                std.posix.close(pipe_fds[1]);
            }

            try setNonBlocking(pipe_fds[0]);
            try setNonBlocking(pipe_fds[1]);

            return .{
                .periph = undefined,
                .io = io,
                .time = time,
                .config = config,
                .pipe_r = pipe_fds[0],
                .pipe_w = pipe_fds[1],
            };
        }

        pub fn bind(self: *Self) void {
            self.periph = .{ .ctx = self, .fd = self.pipe_r, .onReady = onReady };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            std.posix.close(self.pipe_r);
            std.posix.close(self.pipe_w);
        }

        pub fn start(self: *Self) !void {
            if (self.running.load(.acquire)) return;
            self.running.store(true, .release);
            self.count.store(0, .release);
            errdefer self.running.store(false, .release);
            self.worker = try Thread.spawn(
                .{ .stack_size = self.config.thread_stack_size },
                workerMain,
                @ptrCast(self),
            );
        }

        pub fn stop(self: *Self) void {
            if (!self.running.swap(false, .acq_rel)) return;
            if (self.worker) |*th| {
                th.join();
                self.worker = null;
            }
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
        }

        fn workerMain(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            while (self.running.load(.acquire)) {
                self.time.sleepMs(self.config.interval_ms);
                if (!self.running.load(.acquire)) break;

                const c = self.count.fetchAdd(1, .monotonic) + 1;
                const wire = WireEvent{ .count = c };
                _ = std.posix.write(self.pipe_w, std.mem.asBytes(&wire)) catch {};
                self.io.wake();

                if (self.config.mode == .one_shot) {
                    self.running.store(false, .release);
                    break;
                }
            }
        }

        fn onReady(ctx: ?*anyopaque, _: fd_t, buf: *std.ArrayList(EventType), alloc: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            var wire: WireEvent = undefined;
            const wire_bytes = std.mem.asBytes(&wire);
            while (true) {
                const n = std.posix.read(self.pipe_r, wire_bytes) catch break;
                if (n < wire_bytes.len) break;
                buf.append(alloc, @unionInit(EventType, tag, .{
                    .id = self.config.id,
                    .count = wire.count,
                    .interval_ms = self.config.interval_ms,
                })) catch {};
            }
        }

        fn setNonBlocking(fd: fd_t) !void {
            var fl = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
            const mask: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
            fl |= mask;
            _ = try std.posix.fcntl(fd, std.posix.F.SETFL, fl);
        }
    };
}
