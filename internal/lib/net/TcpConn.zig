//! TcpConn — constructs a Conn over a runtime TCP socket (like Go's net.TCPConn).
//!
//! Returns a Conn directly. The internal state is heap-allocated and
//! freed on deinit().

const context_mod = @import("context");
const Conn = @import("Conn.zig");

pub fn TcpConn(comptime lib: type, comptime net: type) type {
    const Allocator = lib.mem.Allocator;
    const Context = context_mod.Context;
    const ContextApi = context_mod.make(lib);
    const Mutex = lib.Thread.Mutex;
    const Runtime = net.Runtime;
    const TcpSocket = Runtime.Tcp;
    // Context-driven waits still use short poll slices because parent context
    // cancellation is not runtime-signaled, but explicit timeout/context setter
    // changes wake blocked polls immediately via runtime interrupts.
    const poll_quantum_ms: i64 = 50;

    return struct {
        socket: TcpSocket,
        allocator: Allocator,
        closed: u8 = 0,
        read_mu: Mutex = .{},
        write_mu: Mutex = .{},
        read_waiting: bool = false,
        write_waiting: bool = false,
        read_timeout_ms: ?u32 = null,
        write_timeout_ms: ?u32 = null,
        read_ctx: ?*SideContext = null,
        write_ctx: ?*SideContext = null,
        read_state_gen: u64 = 0,
        write_state_gen: u64 = 0,

        const Self = @This();
        const WaitState = struct {
            config_gen: ?u64 = null,
            deadline_ms: ?i64 = null,
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

        pub fn setReadTimeout(self: *Self, ms: ?u32) void {
            if (self.isClosed()) return;
            var should_signal = false;
            self.read_mu.lock();
            if (!self.isClosed()) {
                self.read_timeout_ms = ms;
                self.read_state_gen +%= 1;
                should_signal = self.read_waiting;
            }
            self.read_mu.unlock();
            if (should_signal) self.socket.signal(.read_interrupt);
        }

        pub fn setWriteTimeout(self: *Self, ms: ?u32) void {
            if (self.isClosed()) return;
            var should_signal = false;
            self.write_mu.lock();
            if (!self.isClosed()) {
                self.write_timeout_ms = ms;
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
                    const timeout_ms = try self.beginReadWait(wait_state);
                    defer self.endReadWait();
                    break :blk self.socket.poll(.{
                        .read = true,
                        .failed = true,
                        .hup = true,
                        .read_interrupt = true,
                    }, timeout_ms);
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
                    const timeout_ms = try self.beginWriteWait(wait_state);
                    defer self.endWriteWait();
                    break :blk self.socket.poll(.{
                        .write = true,
                        .failed = true,
                        .hup = true,
                        .write_interrupt = true,
                    }, timeout_ms);
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
            if (deadlineExpired(wait_state.deadline_ms)) return error.TimedOut;
            if (self.read_ctx) |side| {
                if (side.ctx.err() != null) return error.TimedOut;
                if (side.ctx.deadline()) |deadline_ns| {
                    if (deadline_ns <= lib.time.nanoTimestamp()) return error.TimedOut;
                }
            }
        }

        fn ensureWriteActive(self: *Self, wait_state: *WaitState) Conn.WriteError!void {
            self.write_mu.lock();
            defer self.write_mu.unlock();

            if (self.isClosed()) return error.BrokenPipe;
            self.syncWriteWaitStateLocked(wait_state);
            if (deadlineExpired(wait_state.deadline_ms)) return error.TimedOut;
            if (self.write_ctx) |side| {
                if (side.ctx.err() != null) return error.TimedOut;
                if (side.ctx.deadline()) |deadline_ns| {
                    if (deadline_ns <= lib.time.nanoTimestamp()) return error.TimedOut;
                }
            }
        }

        fn beginReadWait(self: *Self, wait_state: *WaitState) Conn.ReadError!?u32 {
            self.read_mu.lock();
            defer self.read_mu.unlock();
            if (self.isClosed()) return error.EndOfStream;
            self.syncReadWaitStateLocked(wait_state);
            if (deadlineExpired(wait_state.deadline_ms)) return error.TimedOut;
            if (self.read_ctx) |side| {
                if (side.ctx.err() != null) return error.TimedOut;
                if (side.ctx.deadline()) |deadline_ns| {
                    if (deadline_ns <= lib.time.nanoTimestamp()) return error.TimedOut;
                }
            }
            self.read_waiting = true;
            return pollTimeoutMs(if (self.read_ctx) |side| side.ctx else null, wait_state.deadline_ms);
        }

        fn beginWriteWait(self: *Self, wait_state: *WaitState) Conn.WriteError!?u32 {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            if (self.isClosed()) return error.BrokenPipe;
            self.syncWriteWaitStateLocked(wait_state);
            if (deadlineExpired(wait_state.deadline_ms)) return error.TimedOut;
            if (self.write_ctx) |side| {
                if (side.ctx.err() != null) return error.TimedOut;
                if (side.ctx.deadline()) |deadline_ns| {
                    if (deadline_ns <= lib.time.nanoTimestamp()) return error.TimedOut;
                }
            }
            self.write_waiting = true;
            return pollTimeoutMs(if (self.write_ctx) |side| side.ctx else null, wait_state.deadline_ms);
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
            return waitExpired(if (self.read_ctx) |side| side.ctx else null, wait_state.deadline_ms);
        }

        fn writeWaitExpired(self: *Self, wait_state: *WaitState) bool {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.syncWriteWaitStateLocked(wait_state);
            return waitExpired(if (self.write_ctx) |side| side.ctx else null, wait_state.deadline_ms);
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

        fn timeoutToDeadline(ms: ?u32) ?i64 {
            const timeout_ms = ms orelse return null;
            return lib.time.milliTimestamp() + timeout_ms;
        }

        fn pollTimeoutMs(ctx: ?context_mod.Context, deadline_ms: ?i64) ?u32 {
            var remaining_ms: ?i64 = null;

            if (deadline_ms) |deadline| {
                remaining_ms = deadline - lib.time.milliTimestamp();
            }
            if (ctx) |active_ctx| {
                if (active_ctx.deadline()) |deadline_ns| {
                    const ctx_remaining: i64 = @intCast(@divFloor(deadline_ns - lib.time.nanoTimestamp(), lib.time.ns_per_ms));
                    remaining_ms = if (remaining_ms) |current|
                        @min(current, ctx_remaining)
                    else
                        ctx_remaining;
                }

                const remaining = remaining_ms orelse return @intCast(poll_quantum_ms);
                if (remaining <= 0) return 0;
                return @intCast(@max(@as(i64, 1), @min(remaining, poll_quantum_ms)));
            }

            const remaining = remaining_ms orelse return null;
            if (remaining <= 0) return 0;
            return @intCast(remaining);
        }

        fn waitExpired(ctx: ?Context, deadline_ms: ?i64) bool {
            if (ctx) |active_ctx| {
                if (active_ctx.err() != null) return true;
                if (active_ctx.deadline()) |deadline_ns| {
                    if (deadline_ns <= lib.time.nanoTimestamp()) return true;
                }
            }
            if (deadline_ms) |deadline| {
                return deadline <= lib.time.milliTimestamp();
            }
            return false;
        }

        fn deadlineExpired(deadline_ms: ?i64) bool {
            const deadline = deadline_ms orelse return false;
            return deadline <= lib.time.milliTimestamp();
        }

        fn syncReadWaitStateLocked(self: *Self, wait_state: *WaitState) void {
            if (wait_state.config_gen != self.read_state_gen) {
                wait_state.config_gen = self.read_state_gen;
                wait_state.deadline_ms = timeoutToDeadline(self.read_timeout_ms);
            }
        }

        fn syncWriteWaitStateLocked(self: *Self, wait_state: *WaitState) void {
            if (wait_state.config_gen != self.write_state_gen) {
                wait_state.config_gen = self.write_state_gen;
                wait_state.deadline_ms = timeoutToDeadline(self.write_timeout_ms);
            }
        }
    };
}
