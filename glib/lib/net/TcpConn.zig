//! TcpConn — constructs a Conn over a runtime TCP socket (like Go's net.TCPConn).
//!
//! Returns a Conn directly. The internal state is heap-allocated and
//! freed on deinit().

const time_mod = @import("time");
const context_mod = @import("context");
const Conn = @import("Conn.zig");

pub fn TcpConn(comptime std: type, comptime net: type) type {
    const Allocator = std.mem.Allocator;
    const Context = context_mod.Context;
    const ContextApi = context_mod.make(std, net.time);
    const Mutex = std.Thread.Mutex;
    const Runtime = net.Runtime;
    const TcpSocket = Runtime.Tcp;
    // Context-driven waits still use short poll slices because parent context
    // cancellation is not runtime-signaled, but explicit timeout/context setter
    // changes wake blocked polls immediately via runtime interrupts.
    const poll_quantum: time_mod.duration.Duration = 50 * time_mod.duration.MilliSecond;

    return struct {
        socket: TcpSocket,
        allocator: Allocator,
        closed: u8 = 0,
        read_mu: Mutex = .{},
        write_mu: Mutex = .{},
        read_waiting: bool = false,
        write_waiting: bool = false,
        read_deadline: ?time_mod.instant.Time = null,
        write_deadline: ?time_mod.instant.Time = null,
        read_ctx: ?*SideContext = null,
        write_ctx: ?*SideContext = null,
        read_state_gen: u64 = 0,
        write_state_gen: u64 = 0,

        const Self = @This();
        const WaitState = struct {
            config_gen: ?u64 = null,
            deadline: ?time_mod.instant.Time = null,
        };

        const SideContext = struct {
            allocator: Allocator,
            ctx: Context,

            fn init(allocator: Allocator, parent: Context) Allocator.Error!*SideContext {
                const self = try allocator.create(SideContext);
                errdefer allocator.destroy(self);

                const ctx = try ContextApi.CancelContext.init(parent.allocator, parent);
                errdefer ctx.deinit();

                self.* = .{
                    .allocator = allocator,
                    .ctx = ctx,
                };
                return self;
            }

            fn deinit(self: *SideContext) void {
                self.ctx.deinit();
                self.allocator.destroy(self);
            }
        };

        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.isClosed()) return error.EndOfStream;
            if (buf.len == 0) return 0;

            var wait_state = WaitState{};

            while (true) {
                try ensureReadActive(self, &wait_state);
                const n = self.socket.recv(buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        try waitReadable(self, &wait_state);
                        continue;
                    },
                    error.Closed => return error.EndOfStream,
                    error.ConnectionReset => return error.ConnectionReset,
                    error.ConnectionRefused => return error.ConnectionRefused,
                    error.TimedOut => return error.TimedOut,
                    else => {
                        if (self.isClosed()) return error.EndOfStream;
                        return error.Unexpected;
                    },
                };
                if (n == 0) return error.EndOfStream;
                return n;
            }
        }

        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.isClosed()) return error.BrokenPipe;

            var wait_state = WaitState{};

            while (true) {
                try ensureWriteActive(self, &wait_state);
                const n = self.socket.send(buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        try waitWritable(self, &wait_state);
                        continue;
                    },
                    error.Closed => return error.BrokenPipe,
                    error.ConnectionRefused => return error.ConnectionRefused,
                    error.ConnectionReset => return error.ConnectionReset,
                    error.BrokenPipe => return error.BrokenPipe,
                    error.TimedOut => return error.TimedOut,
                    else => {
                        if (self.isClosed()) return error.BrokenPipe;
                        return error.Unexpected;
                    },
                };
                return n;
            }
        }

        pub fn close(self: *Self) void {
            if (self.markClosed()) return;
            self.socket.signal(.read_interrupt);
            self.socket.signal(.write_interrupt);
            self.socket.shutdown(.both) catch {};
            self.socket.close();
            self.clearReadContext();
            self.clearWriteContext();
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.socket.deinit();
            self.allocator.destroy(self);
        }

        pub fn setReadDeadline(self: *Self, deadline: ?time_mod.instant.Time) void {
            if (self.isClosed()) return;
            var should_signal = false;
            self.read_mu.lock();
            if (!self.isClosed()) {
                self.read_deadline = deadline;
                self.read_state_gen +%= 1;
                should_signal = self.read_waiting;
            }
            self.read_mu.unlock();
            if (should_signal) self.socket.signal(.read_interrupt);
        }

        pub fn setWriteDeadline(self: *Self, deadline: ?time_mod.instant.Time) void {
            if (self.isClosed()) return;
            var should_signal = false;
            self.write_mu.lock();
            if (!self.isClosed()) {
                self.write_deadline = deadline;
                self.write_state_gen +%= 1;
                should_signal = self.write_waiting;
            }
            self.write_mu.unlock();
            if (should_signal) self.socket.signal(.write_interrupt);
        }

        pub fn setReadContext(self: *Self, ctx: ?context_mod.Context) Allocator.Error!void {
            if (self.isClosed()) return;
            const new_ctx = if (ctx) |parent|
                try SideContext.init(self.allocator, parent)
            else
                null;
            errdefer if (new_ctx) |side| side.deinit();

            var to_deinit = new_ctx;
            var should_signal = false;
            self.read_mu.lock();
            if (!self.isClosed()) {
                to_deinit = self.read_ctx;
                self.read_ctx = new_ctx;
                self.read_state_gen +%= 1;
                should_signal = self.read_waiting;
            }
            self.read_mu.unlock();
            if (to_deinit) |side| side.deinit();
            if (should_signal) self.socket.signal(.read_interrupt);
        }

        pub fn setWriteContext(self: *Self, ctx: ?context_mod.Context) Allocator.Error!void {
            if (self.isClosed()) return;
            const new_ctx = if (ctx) |parent|
                try SideContext.init(self.allocator, parent)
            else
                null;
            errdefer if (new_ctx) |side| side.deinit();

            var to_deinit = new_ctx;
            var should_signal = false;
            self.write_mu.lock();
            if (!self.isClosed()) {
                to_deinit = self.write_ctx;
                self.write_ctx = new_ctx;
                self.write_state_gen +%= 1;
                should_signal = self.write_waiting;
            }
            self.write_mu.unlock();
            if (to_deinit) |side| side.deinit();
            if (should_signal) self.socket.signal(.write_interrupt);
        }

        pub fn initFromSocket(allocator: Allocator, socket: TcpSocket) Allocator.Error!Conn {
            const self = try allocator.create(Self);
            self.* = .{
                .socket = socket,
                .allocator = allocator,
            };
            return Conn.init(self);
        }

        fn waitReadable(self: *Self, wait_state: *WaitState) Conn.ReadError!void {
            while (true) {
                if (self.isClosed()) return error.EndOfStream;
                const poll_result = blk: {
                    const timeout = try self.beginReadWait(wait_state);
                    defer self.endReadWait();
                    break :blk self.socket.poll(.{
                        .read = true,
                        .failed = true,
                        .hup = true,
                        .read_interrupt = true,
                    }, timeout);
                };
                _ = poll_result catch |err| switch (err) {
                    error.Closed => return error.EndOfStream,
                    error.TimedOut => {
                        if (self.readWaitExpired(wait_state)) return error.TimedOut;
                        continue;
                    },
                    else => return error.Unexpected,
                };
                return;
            }
        }

        fn waitWritable(self: *Self, wait_state: *WaitState) Conn.WriteError!void {
            while (true) {
                if (self.isClosed()) return error.BrokenPipe;
                const poll_result = blk: {
                    const timeout = try self.beginWriteWait(wait_state);
                    defer self.endWriteWait();
                    break :blk self.socket.poll(.{
                        .write = true,
                        .failed = true,
                        .hup = true,
                        .write_interrupt = true,
                    }, timeout);
                };
                _ = poll_result catch |err| switch (err) {
                    error.Closed => return error.BrokenPipe,
                    error.TimedOut => {
                        if (self.writeWaitExpired(wait_state)) return error.TimedOut;
                        continue;
                    },
                    else => return error.Unexpected,
                };
                return;
            }
        }

        fn ensureReadActive(self: *Self, wait_state: *WaitState) Conn.ReadError!void {
            self.read_mu.lock();
            defer self.read_mu.unlock();

            if (self.isClosed()) return error.EndOfStream;
            self.syncReadWaitStateLocked(wait_state);
            if (waitExpired(null, wait_state.deadline)) return error.TimedOut;
            if (self.read_ctx) |side| {
                if (side.ctx.err() != null) return error.TimedOut;
                if (waitExpired(side.ctx, null)) return error.TimedOut;
            }
        }

        fn ensureWriteActive(self: *Self, wait_state: *WaitState) Conn.WriteError!void {
            self.write_mu.lock();
            defer self.write_mu.unlock();

            if (self.isClosed()) return error.BrokenPipe;
            self.syncWriteWaitStateLocked(wait_state);
            if (waitExpired(null, wait_state.deadline)) return error.TimedOut;
            if (self.write_ctx) |side| {
                if (side.ctx.err() != null) return error.TimedOut;
                if (waitExpired(side.ctx, null)) return error.TimedOut;
            }
        }

        fn beginReadWait(self: *Self, wait_state: *WaitState) Conn.ReadError!?time_mod.duration.Duration {
            self.read_mu.lock();
            defer self.read_mu.unlock();
            if (self.isClosed()) return error.EndOfStream;
            self.syncReadWaitStateLocked(wait_state);
            if (waitExpired(null, wait_state.deadline)) return error.TimedOut;
            if (self.read_ctx) |side| {
                if (side.ctx.err() != null) return error.TimedOut;
                if (waitExpired(side.ctx, null)) return error.TimedOut;
            }
            self.read_waiting = true;
            return pollTimeout(if (self.read_ctx) |side| side.ctx else null, wait_state.deadline);
        }

        fn beginWriteWait(self: *Self, wait_state: *WaitState) Conn.WriteError!?time_mod.duration.Duration {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            if (self.isClosed()) return error.BrokenPipe;
            self.syncWriteWaitStateLocked(wait_state);
            if (waitExpired(null, wait_state.deadline)) return error.TimedOut;
            if (self.write_ctx) |side| {
                if (side.ctx.err() != null) return error.TimedOut;
                if (waitExpired(side.ctx, null)) return error.TimedOut;
            }
            self.write_waiting = true;
            return pollTimeout(if (self.write_ctx) |side| side.ctx else null, wait_state.deadline);
        }

        fn endReadWait(self: *Self) void {
            self.read_mu.lock();
            defer self.read_mu.unlock();
            self.read_waiting = false;
        }

        fn endWriteWait(self: *Self) void {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.write_waiting = false;
        }

        fn readWaitExpired(self: *Self, wait_state: *WaitState) bool {
            self.read_mu.lock();
            defer self.read_mu.unlock();
            self.syncReadWaitStateLocked(wait_state);
            return waitExpired(if (self.read_ctx) |side| side.ctx else null, wait_state.deadline);
        }

        fn writeWaitExpired(self: *Self, wait_state: *WaitState) bool {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.syncWriteWaitStateLocked(wait_state);
            return waitExpired(if (self.write_ctx) |side| side.ctx else null, wait_state.deadline);
        }

        fn clearReadContext(self: *Self) void {
            var old_ctx: ?*SideContext = null;
            self.read_mu.lock();
            old_ctx = self.read_ctx;
            self.read_ctx = null;
            self.read_mu.unlock();
            if (old_ctx) |side| side.deinit();
        }

        fn clearWriteContext(self: *Self) void {
            var old_ctx: ?*SideContext = null;
            self.write_mu.lock();
            old_ctx = self.write_ctx;
            self.write_ctx = null;
            self.write_mu.unlock();
            if (old_ctx) |side| side.deinit();
        }

        fn isClosed(self: *const Self) bool {
            return @atomicLoad(u8, &self.closed, .acquire) != 0;
        }

        fn markClosed(self: *Self) bool {
            return @atomicRmw(u8, &self.closed, .Xchg, 1, .acq_rel) != 0;
        }

        fn pollTimeout(ctx: ?context_mod.Context, deadline: ?time_mod.instant.Time) ?time_mod.duration.Duration {
            var remaining: ?time_mod.duration.Duration = if (deadline) |value|
                @max(time_mod.instant.sub(value, net.time.instant.now()), 0)
            else
                null;
            if (ctx) |active_ctx| {
                if (active_ctx.deadline()) |ctx_deadline| {
                    const ctx_remaining = @max(time_mod.instant.sub(ctx_deadline, net.time.instant.now()), 0);
                    remaining = if (remaining) |value| @min(value, ctx_remaining) else ctx_remaining;
                }

                const timeout = remaining orelse return poll_quantum;
                return @min(timeout, poll_quantum);
            }

            return remaining;
        }

        fn waitExpired(ctx: ?Context, deadline: ?time_mod.instant.Time) bool {
            if (ctx) |active_ctx| {
                if (active_ctx.err() != null) return true;
                if (active_ctx.deadline()) |value| {
                    if (time_mod.instant.sub(value, net.time.instant.now()) <= 0) return true;
                }
            }
            const value = deadline orelse return false;
            return time_mod.instant.sub(value, net.time.instant.now()) <= 0;
        }

        fn syncReadWaitStateLocked(self: *Self, wait_state: *WaitState) void {
            if (wait_state.config_gen != self.read_state_gen) {
                wait_state.config_gen = self.read_state_gen;
                wait_state.deadline = self.read_deadline;
            }
        }

        fn syncWriteWaitStateLocked(self: *Self, wait_state: *WaitState) void {
            if (wait_state.config_gen != self.write_state_gen) {
                wait_state.config_gen = self.write_state_gen;
                wait_state.deadline = self.write_deadline;
            }
        }
    };
}
