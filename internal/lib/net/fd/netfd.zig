const context_mod = @import("context");
const wake_mod = @import("Wake.zig");

pub fn make(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const posix = lib.posix;
    const Context = context_mod.Context;
    const ContextApi = context_mod.make(lib);
    const Wake = wake_mod.make(lib);
    const max_poll_timeout_ms: i64 = 2_147_483_647;

    return struct {
        read_side: SideState,
        write_side: SideState,

        const Self = @This();

        pub const InitError = SideState.InitError;
        pub const WaitError = error{ Closed, TimedOut } || Context.StateError || posix.PollError;
        pub const ConnectWaitError = WaitError;

        const SideState = struct {
            wake: Wake,
            deadline_mu: lib.Thread.Mutex = .{},
            deadline_ms: ?i64 = null,
            context_mu: lib.Thread.Mutex = .{},
            context: ?Context = null,

            const Side = @This();

            pub const InitError = Wake.InitError;

            fn init() Wake.InitError!Side {
                return .{
                    .wake = try Wake.init(),
                };
            }

            fn deinit(self: *Side) void {
                self.setContext(null) catch unreachable;
                self.wake.deinit();
            }

            fn signal(self: *const Side) void {
                self.wake.signal();
            }

            fn setDeadline(self: *Side, deadline_ms: ?i64) void {
                self.deadline_mu.lock();
                self.deadline_ms = deadline_ms;
                self.deadline_mu.unlock();
                self.signal();
            }

            fn deadline(self: *Side) ?i64 {
                self.deadline_mu.lock();
                defer self.deadline_mu.unlock();
                return self.deadline_ms;
            }

            fn setContext(self: *Side, parent_ctx: ?Context) Allocator.Error!void {
                var new_child: ?Context = null;
                errdefer if (new_child) |child| child.deinit();
                if (parent_ctx) |parent| {
                    new_child = try ContextApi.CancelContext.init(parent.allocator, parent);
                }

                self.context_mu.lock();
                const old_child = self.context;
                self.context = new_child;
                self.context_mu.unlock();

                if (old_child) |child| {
                    // Replacing the side context must first detach the old child
                    // from this wake fd so future cancels/deadlines stop targeting it.
                    child.bindLink(null) catch unreachable;
                    child.deinit();
                }
                if (new_child) |child| {
                    child.bindFd(lib, &self.wake.send_fd) catch unreachable;
                }

                self.signal();
            }

            fn checkContextState(self: *Side) Context.StateError!void {
                self.context_mu.lock();
                const child = self.context;
                self.context_mu.unlock();

                if (child) |ctx| try ctx.checkState();
            }

            fn waitReady(self: *Side, fd: posix.socket_t, events: anytype, closed: *const bool) WaitError!void {
                var poll_fds = [2]posix.pollfd{
                    .{
                        .fd = fd,
                        .events = events,
                        .revents = 0,
                    },
                    .{
                        .fd = self.wake.recv_fd,
                        .events = posix.POLL.IN,
                        .revents = 0,
                    },
                };

                while (true) {
                    if (closed.*) return error.Closed;
                    try self.checkContextState();

                    poll_fds[0].revents = 0;
                    poll_fds[1].revents = 0;
                    const ready = posix.poll(poll_fds[0..], timeoutFromDeadline(self.deadline())) catch |err| {
                        if (errorNameEquals(err, "Interrupted")) continue;
                        return err;
                    };

                    if (ready == 0) {
                        if (closed.*) return error.Closed;
                        try self.checkContextState();
                        return error.TimedOut;
                    }
                    if (poll_fds[1].revents != 0) {
                        self.wake.drain();
                        if (closed.*) return error.Closed;
                        try self.checkContextState();
                        // Any setter-driven wake means the side state may have changed.
                        // Recompute deadline/context and poll again.
                        continue;
                    }
                    if (poll_fds[0].revents != 0) {
                        if (closed.*) return error.Closed;
                        return;
                    }
                }
            }

            fn timeoutFromDeadline(deadline_ms: ?i64) i32 {
                const deadline_value = deadline_ms orelse return -1;
                const now = lib.time.milliTimestamp();
                const remaining = deadline_value - now;
                if (remaining <= 0) return 0;
                return @intCast(@min(remaining, max_poll_timeout_ms));
            }

            fn errorNameEquals(err: anyerror, comptime expected: []const u8) bool {
                const name = @errorName(err);
                if (name.len != expected.len) return false;
                inline for (expected, 0..) |byte, i| {
                    if (name[i] != byte) return false;
                }
                return true;
            }
        };

        pub fn init() InitError!Self {
            return .{
                .read_side = try SideState.init(),
                .write_side = try SideState.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.read_side.deinit();
            self.write_side.deinit();
        }

        pub fn clearContexts(self: *Self) void {
            self.read_side.setContext(null) catch unreachable;
            self.write_side.setContext(null) catch unreachable;
        }

        pub fn signalRead(self: *const Self) void {
            self.read_side.signal();
        }

        pub fn signalWrite(self: *const Self) void {
            self.write_side.signal();
        }

        pub fn signalAll(self: *const Self) void {
            self.read_side.signal();
            self.write_side.signal();
        }

        pub fn setReadDeadline(self: *Self, deadline_ms: ?i64) void {
            self.read_side.setDeadline(deadline_ms);
        }

        pub fn setWriteDeadline(self: *Self, deadline_ms: ?i64) void {
            self.write_side.setDeadline(deadline_ms);
        }

        pub fn readDeadline(self: *Self) ?i64 {
            return self.read_side.deadline();
        }

        pub fn writeDeadline(self: *Self) ?i64 {
            return self.write_side.deadline();
        }

        pub fn setReadContext(self: *Self, ctx: ?Context) Allocator.Error!void {
            try self.read_side.setContext(ctx);
        }

        pub fn setWriteContext(self: *Self, ctx: ?Context) Allocator.Error!void {
            try self.write_side.setContext(ctx);
        }

        pub fn checkReadContextState(self: *Self) Context.StateError!void {
            try self.read_side.checkContextState();
        }

        pub fn checkWriteContextState(self: *Self) Context.StateError!void {
            try self.write_side.checkContextState();
        }

        pub fn waitReadable(self: *Self, fd: posix.socket_t, closed: *const bool) WaitError!void {
            return self.read_side.waitReady(fd, posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, closed);
        }

        pub fn waitWritable(self: *Self, fd: posix.socket_t, closed: *const bool) WaitError!void {
            return self.write_side.waitReady(fd, posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR, closed);
        }

        pub fn waitConnect(self: *Self, fd: posix.socket_t, closed: *const bool) ConnectWaitError!void {
            // Connect is treated as a write-side wait: writability or wake means
            // the connect state changed and should be re-evaluated.
            return self.write_side.waitReady(fd, posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR, closed);
        }
    };
}
