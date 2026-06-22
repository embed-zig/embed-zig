const glib = @import("glib");
const binding = @import("channel/binding.zig");
const sync = glib.sync;

const Handle = binding.Handle;
const pd_true = binding.pd_true;
const poll_ticks: u32 = 1;
const ns_per_s: u64 = 1_000_000_000;
const Alignment = glib.std.mem.Alignment;

pub const ChannelFactory: sync.channel.FactoryType = struct {
    fn factory(comptime std: type) sync.channel.ChannelType {
        _ = std;
        return Channel;
    }
}.factory;

pub const Error = error{
    CreateFailed,
    InvalidCapacity,
};

pub const SendResult = sync.channel.SendResult;
pub const RecvResult = sync.channel.RecvResult;

const AlignedStorage = struct {
    bytes: []u8,
    alignment: Alignment,
};

pub fn Channel(comptime T: type) type {
    comptime {
        if (@sizeOf(T) == 0) @compileError("freertos.Channel does not support zero-sized element types");
    }

    return struct {
        allocator: glib.std.mem.Allocator,
        queue: Handle = null,
        state_lock: Handle = null,
        send_lock: Handle = null,
        ack: Handle = null,
        queue_control_storage: ?AlignedStorage = null,
        queue_item_storage: ?[]u8 = null,
        state_lock_storage: ?AlignedStorage = null,
        send_lock_storage: ?AlignedStorage = null,
        ack_storage: ?AlignedStorage = null,
        capacity: usize,
        closed: bool = false,
        recv_waiters: u32 = 0,

        const Self = @This();

        pub fn init(allocator: glib.std.mem.Allocator, capacity: usize) anyerror!Self {
            if (capacity > glib.std.math.maxInt(u32)) return error.InvalidCapacity;

            var self = Self{
                .allocator = allocator,
                .capacity = capacity,
            };
            errdefer self.deinit();

            const queue_len: u32 = if (capacity == 0) 1 else @intCast(capacity);
            self.queue_control_storage = try allocAlignedStorage(
                allocator,
                binding.espz_channel_static_queue_size(),
                binding.espz_channel_static_queue_align(),
            );
            self.queue_item_storage = try allocStorage(allocator, queueStorageSize(queue_len, @sizeOf(T)) orelse return error.InvalidCapacity);
            self.queue = binding.espz_channel_queue_create_static(
                queue_len,
                @sizeOf(T),
                self.queue_item_storage.?.ptr,
                self.queue_control_storage.?.bytes.ptr,
            ) orelse return error.CreateFailed;

            self.state_lock_storage = try allocSemaphoreStorage(allocator);
            self.state_lock = binding.espz_channel_semaphore_create_mutex_static(self.state_lock_storage.?.bytes.ptr) orelse
                return error.CreateFailed;

            if (capacity == 0) {
                self.send_lock_storage = try allocSemaphoreStorage(allocator);
                self.send_lock = binding.espz_channel_semaphore_create_mutex_static(self.send_lock_storage.?.bytes.ptr) orelse
                    return error.CreateFailed;
                self.ack_storage = try allocSemaphoreStorage(allocator);
                self.ack = binding.espz_channel_semaphore_create_binary_static(self.ack_storage.?.bytes.ptr) orelse
                    return error.CreateFailed;
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.close();
            deleteSemaphore(&self.ack);
            deleteSemaphore(&self.send_lock);
            deleteSemaphore(&self.state_lock);
            deleteQueue(&self.queue);
            freeAlignedStorage(self.allocator, &self.ack_storage);
            freeAlignedStorage(self.allocator, &self.send_lock_storage);
            freeAlignedStorage(self.allocator, &self.state_lock_storage);
            freeStorage(self.allocator, &self.queue_item_storage);
            freeAlignedStorage(self.allocator, &self.queue_control_storage);
        }

        pub fn close(self: *Self) void {
            if (self.state_lock == null) return;
            self.lock();
            self.closed = true;
            self.unlock();
        }

        pub fn send(self: *Self, value: T) anyerror!SendResult() {
            return if (self.capacity == 0)
                self.sendUnbuffered(value)
            else
                self.sendBuffered(value);
        }

        pub fn sendTimeout(self: *Self, value: T, timeout: glib.time.duration.Duration) anyerror!SendResult() {
            const timeout_ticks = durationToTicks(timeout);
            return if (self.capacity == 0)
                self.sendUnbufferedTimeout(value, timeout_ticks)
            else
                self.sendBufferedTimeout(value, timeout_ticks);
        }

        pub fn recv(self: *Self) anyerror!RecvResult(T) {
            return if (self.capacity == 0)
                self.recvUnbuffered()
            else
                self.recvBuffered();
        }

        pub fn recvTimeout(self: *Self, timeout: glib.time.duration.Duration) anyerror!RecvResult(T) {
            const timeout_ticks = durationToTicks(timeout);
            return if (self.capacity == 0)
                self.recvUnbufferedTimeout(timeout_ticks)
            else
                self.recvBufferedTimeout(timeout_ticks);
        }

        fn sendBuffered(self: *Self, value: T) SendResult() {
            var item = value;
            while (true) {
                if (self.isClosed()) return .{ .ok = false };
                if (binding.espz_channel_queue_send(self.queue, @ptrCast(&item), poll_ticks) == pd_true) {
                    return .{ .ok = true };
                }
            }
        }

        fn sendBufferedTimeout(self: *Self, value: T, timeout_ticks: u32) anyerror!SendResult() {
            var item = value;
            var remaining: u32 = timeout_ticks;
            while (true) {
                if (self.isClosed()) return .{ .ok = false };
                const wait = @min(poll_ticks, remaining);
                if (binding.espz_channel_queue_send(self.queue, @ptrCast(&item), wait) == pd_true) {
                    return .{ .ok = true };
                }
                if (self.isClosed()) return .{ .ok = false };
                if (remaining <= poll_ticks) {
                    return error.Timeout;
                }
                remaining -= poll_ticks;
            }
        }

        fn recvBuffered(self: *Self) RecvResult(T) {
            while (true) {
                var item: T = undefined;
                if (binding.espz_channel_queue_receive(self.queue, @ptrCast(&item), poll_ticks) == pd_true) {
                    return .{ .value = item, .ok = true };
                }
                if (self.isClosedAndEmpty()) {
                    return .{ .value = undefined, .ok = false };
                }
            }
        }

        fn recvBufferedTimeout(self: *Self, timeout_ticks: u32) anyerror!RecvResult(T) {
            var remaining: u32 = timeout_ticks;
            while (true) {
                var item: T = undefined;
                const wait = @min(poll_ticks, remaining);
                if (binding.espz_channel_queue_receive(self.queue, @ptrCast(&item), wait) == pd_true) {
                    return .{ .value = item, .ok = true };
                }
                if (self.isClosedAndEmpty()) {
                    return .{ .value = undefined, .ok = false };
                }
                if (remaining <= poll_ticks) {
                    return error.Timeout;
                }
                remaining -= poll_ticks;
            }
        }

        fn sendUnbuffered(self: *Self, value: T) SendResult() {
            const send_lock = self.send_lock orelse unreachable;
            lockSemaphore(send_lock);
            defer _ = binding.espz_channel_semaphore_give(send_lock);

            var item = value;
            while (true) {
                if (self.isClosed()) return .{ .ok = false };
                if (self.hasWaitingReceiver()) {
                    if (binding.espz_channel_queue_send(self.queue, @ptrCast(&item), poll_ticks) == pd_true) {
                        break;
                    }
                }
                pause();
            }

            const ack = self.ack orelse unreachable;
            while (true) {
                if (binding.espz_channel_semaphore_take(ack, poll_ticks) == pd_true) {
                    return .{ .ok = true };
                }
                if (self.isClosed() and binding.espz_channel_queue_messages_waiting(self.queue) == 0) {
                    return .{ .ok = false };
                }
            }
        }

        fn sendUnbufferedTimeout(self: *Self, value: T, timeout_ticks: u32) anyerror!SendResult() {
            const send_lock = self.send_lock orelse unreachable;
            lockSemaphore(send_lock);
            defer _ = binding.espz_channel_semaphore_give(send_lock);

            var item = value;
            var remaining: u32 = timeout_ticks;
            while (true) {
                if (self.isClosed()) return .{ .ok = false };
                if (self.hasWaitingReceiver()) {
                    const wait = @min(poll_ticks, remaining);
                    if (binding.espz_channel_queue_send(self.queue, @ptrCast(&item), wait) == pd_true) {
                        break;
                    }
                } else if (remaining <= poll_ticks) {
                    return error.Timeout;
                }

                if (self.isClosed()) return .{ .ok = false };
                if (remaining <= poll_ticks) {
                    return error.Timeout;
                }
                remaining -= poll_ticks;
                pause();
            }

            const ack = self.ack orelse unreachable;
            while (true) {
                const wait = @min(poll_ticks, remaining);
                if (binding.espz_channel_semaphore_take(ack, wait) == pd_true) {
                    return .{ .ok = true };
                }
                if (self.isClosed() and binding.espz_channel_queue_messages_waiting(self.queue) == 0) {
                    return .{ .ok = false };
                }
                if (remaining <= poll_ticks) {
                    return error.Timeout;
                }
                remaining -= poll_ticks;
            }
        }

        fn recvUnbuffered(self: *Self) RecvResult(T) {
            while (true) {
                self.lock();
                self.recv_waiters += 1;
                self.unlock();

                var item: T = undefined;
                const received = binding.espz_channel_queue_receive(self.queue, @ptrCast(&item), poll_ticks) == pd_true;

                self.lock();
                if (self.recv_waiters != 0) self.recv_waiters -= 1;
                const closed = self.closed;
                const empty = binding.espz_channel_queue_messages_waiting(self.queue) == 0;
                self.unlock();

                if (received) {
                    _ = binding.espz_channel_semaphore_give(self.ack);
                    return .{ .value = item, .ok = true };
                }
                if (closed and empty) {
                    return .{ .value = undefined, .ok = false };
                }
            }
        }

        fn recvUnbufferedTimeout(self: *Self, timeout_ticks: u32) anyerror!RecvResult(T) {
            var remaining: u32 = timeout_ticks;
            while (true) {
                self.lock();
                self.recv_waiters += 1;
                self.unlock();

                var item: T = undefined;
                const wait = @min(poll_ticks, remaining);
                const received = binding.espz_channel_queue_receive(self.queue, @ptrCast(&item), wait) == pd_true;

                self.lock();
                if (self.recv_waiters != 0) self.recv_waiters -= 1;
                const closed = self.closed;
                const empty = binding.espz_channel_queue_messages_waiting(self.queue) == 0;
                self.unlock();

                if (received) {
                    _ = binding.espz_channel_semaphore_give(self.ack);
                    return .{ .value = item, .ok = true };
                }
                if (closed and empty) {
                    return .{ .value = undefined, .ok = false };
                }
                if (remaining <= poll_ticks) {
                    return error.Timeout;
                }
                remaining -= poll_ticks;
            }
        }

        fn hasWaitingReceiver(self: *Self) bool {
            self.lock();
            defer self.unlock();
            return self.recv_waiters != 0 and !self.closed;
        }

        fn isClosed(self: *Self) bool {
            self.lock();
            defer self.unlock();
            return self.closed;
        }

        fn isClosedAndEmpty(self: *Self) bool {
            self.lock();
            defer self.unlock();
            return self.closed and binding.espz_channel_queue_messages_waiting(self.queue) == 0;
        }

        fn lock(self: *Self) void {
            lockSemaphore(self.state_lock);
        }

        fn unlock(self: *Self) void {
            _ = binding.espz_channel_semaphore_give(self.state_lock);
        }
    };
}

fn durationToTicks(duration: glib.time.duration.Duration) u32 {
    if (duration <= 0) return 0;
    return nsToTicksCeil(@intCast(duration));
}

fn nsToTicksCeil(timeout_ns: u64) u32 {
    if (timeout_ns == 0) return 0;

    const tick_rate_hz = binding.espz_channel_tick_rate_hz();
    if (tick_rate_hz == 0) return binding.max_delay;

    const tick_ns = ns_per_s / tick_rate_hz;
    if (tick_ns == 0) return binding.max_delay;

    const extra = tick_ns - 1;
    const adjusted, const overflow = @addWithOverflow(timeout_ns, extra);
    if (overflow != 0) return binding.max_delay;

    const ticks = adjusted / tick_ns;
    if (ticks > binding.max_delay) return binding.max_delay;
    return @intCast(ticks);
}

fn allocStorage(allocator: glib.std.mem.Allocator, size: usize) ![]u8 {
    if (size == 0) return error.CreateFailed;
    return allocator.alloc(u8, size) catch return error.CreateFailed;
}

fn allocAlignedStorage(allocator: glib.std.mem.Allocator, size: u32, align_bytes: u32) !AlignedStorage {
    if (size == 0) return error.CreateFailed;
    const alignment = alignmentFromBytes(align_bytes) catch return error.CreateFailed;
    const bytes = allocator.rawAlloc(size, alignment, @returnAddress()) orelse return error.CreateFailed;
    return .{
        .bytes = bytes[0..size],
        .alignment = alignment,
    };
}

fn allocSemaphoreStorage(allocator: glib.std.mem.Allocator) !AlignedStorage {
    return allocAlignedStorage(
        allocator,
        binding.espz_channel_static_semaphore_size(),
        binding.espz_channel_static_semaphore_align(),
    );
}

fn freeStorage(allocator: glib.std.mem.Allocator, storage: *?[]u8) void {
    if (storage.*) |value| {
        allocator.free(value);
        storage.* = null;
    }
}

fn freeAlignedStorage(allocator: glib.std.mem.Allocator, storage: *?AlignedStorage) void {
    if (storage.*) |value| {
        allocator.rawFree(value.bytes, value.alignment, @returnAddress());
        storage.* = null;
    }
}

fn alignmentFromBytes(bytes: usize) error{InvalidAlignment}!Alignment {
    return switch (bytes) {
        1 => .@"1",
        2 => .@"2",
        4 => .@"4",
        8 => .@"8",
        16 => .@"16",
        32 => .@"32",
        64 => .@"64",
        else => error.InvalidAlignment,
    };
}

fn queueStorageSize(length: u32, item_size: usize) ?usize {
    const len: usize = length;
    const size, const overflow = @mulWithOverflow(len, item_size);
    if (overflow != 0) return null;
    return size;
}

fn lockSemaphore(handle: Handle) void {
    while (binding.espz_channel_semaphore_take(handle, binding.max_delay) != pd_true) {}
}

fn pause() void {
    binding.espz_channel_task_yield();
}

fn deleteSemaphore(handle: *Handle) void {
    if (handle.*) |value| {
        binding.espz_channel_semaphore_delete(value);
        handle.* = null;
    }
}

fn deleteQueue(handle: *Handle) void {
    if (handle.*) |value| {
        binding.espz_channel_queue_delete(value);
        handle.* = null;
    }
}
