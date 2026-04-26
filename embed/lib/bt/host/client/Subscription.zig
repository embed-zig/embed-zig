//! host.client.Subscription — queue of server pushes for one characteristic.

const glib = @import("glib");

const bt = @import("../../../bt.zig");

pub fn Subscription(comptime lib: type, comptime ClientType: type) type {
    return struct {
        pub const Message = bt.Central.NotificationData;

        pub const State = struct {
            allocator: lib.mem.Allocator,
            client: ?*ClientType,
            conn_handle: u16,
            value_handle: u16,
            cccd_handle: u16,
            mutex: lib.Thread.Mutex = .{},
            cond: lib.Thread.Condition = .{},
            queue: glib.std.ArrayListUnmanaged(Message) = .{},
            closed: bool = false,
            waiters: usize = 0,
            refs: usize = 1,
        };

        state: *State,

        const Self = @This();

        pub fn init(
            allocator: lib.mem.Allocator,
            client: *ClientType,
            conn_handle: u16,
            value_handle: u16,
            cccd_handle: u16,
        ) !Self {
            const state = try allocator.create(State);
            state.* = .{
                .allocator = allocator,
                .client = client,
                .conn_handle = conn_handle,
                .value_handle = value_handle,
                .cccd_handle = cccd_handle,
            };
            return .{ .state = state };
        }

        pub fn deinit(self: *Self) void {
            if (self.state.client) |client| {
                _ = client.unregisterSubscription(self.state, true);
            }
            releaseState(self.state);
        }

        pub fn next(self: *Self, timeout_ms: ?u32) error{TimedOut}!?Message {
            return nextState(self.state, timeout_ms);
        }

        pub fn matches(state: *const State, conn_handle: u16, attr_handle: u16) bool {
            return state.conn_handle == conn_handle and state.value_handle == attr_handle;
        }

        pub fn push(state: *State, msg: Message) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            if (state.closed) return;
            state.queue.append(state.allocator, msg) catch {
                state.closed = true;
                state.cond.broadcast();
                return;
            };
            state.cond.signal();
        }

        pub fn close(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.closed = true;
            state.cond.broadcast();
        }

        pub fn retainState(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.refs += 1;
        }

        pub fn detachClient(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.client = null;
            state.closed = true;
            state.cond.broadcast();
        }

        pub fn releaseState(state: *State) void {
            state.mutex.lock();
            state.closed = true;
            state.cond.broadcast();
            glib.std.debug.assert(state.refs != 0);
            state.refs -= 1;
            if (state.refs != 0) {
                state.mutex.unlock();
                return;
            }
            while (state.waiters != 0) {
                state.cond.wait(&state.mutex);
            }
            state.mutex.unlock();
            state.queue.deinit(state.allocator);
            state.allocator.destroy(state);
        }

        fn nextState(state: *State, timeout_ms: ?u32) error{TimedOut}!?Message {
            state.mutex.lock();
            state.waiters += 1;
            defer {
                state.waiters -= 1;
                if (state.waiters == 0) {
                    state.cond.broadcast();
                }
                state.mutex.unlock();
            }

            while (state.queue.items.len == 0 and !state.closed) {
                if (timeout_ms) |ms| {
                    state.cond.timedWait(&state.mutex, @as(u64, ms) * 1_000_000) catch |err| switch (err) {
                        error.Timeout => return error.TimedOut,
                    };
                } else {
                    state.cond.wait(&state.mutex);
                }
            }

            if (state.queue.items.len == 0) return null;
            return state.queue.orderedRemove(0);
        }
    };
}
