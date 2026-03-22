//! Channel impl backed by dual-pipe MPMC, supports buffered and unbuffered.
//!
//! Copied from websim runtime channel_factory on main branch,
//! adapted to embed v2 Channel contract.

const std = @import("std");
const channel = @import("sync").channel;

pub fn Channel(comptime T: type) type {
    return struct {
        inner: *Inner,

        const Self = @This();

        const Inner = struct {
            allocator: std.mem.Allocator,
            mutex: std.Thread.Mutex,
            ring: []T,
            head: usize,
            tail: usize,
            len: usize,
            capacity: usize,
            read_pipe_r: std.posix.fd_t,
            read_pipe_w: std.posix.fd_t,
            write_pipe_r: std.posix.fd_t,
            write_pipe_w: std.posix.fd_t,
            closed: bool,
            slot: T,
            send_mutex: std.Thread.Mutex,
        };

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const ring: []T = if (capacity > 0)
                try allocator.alloc(T, capacity)
            else
                @constCast(&[_]T{});
            errdefer if (capacity > 0) allocator.free(ring);

            const read_pipe = try std.posix.pipe();
            errdefer {
                std.posix.close(read_pipe[0]);
                std.posix.close(read_pipe[1]);
            }

            const write_pipe = try std.posix.pipe();
            errdefer {
                std.posix.close(write_pipe[0]);
                std.posix.close(write_pipe[1]);
            }

            const inner = try allocator.create(Inner);
            inner.* = .{
                .allocator = allocator,
                .mutex = .{},
                .ring = ring,
                .head = 0,
                .tail = 0,
                .len = 0,
                .capacity = capacity,
                .read_pipe_r = read_pipe[0],
                .read_pipe_w = read_pipe[1],
                .write_pipe_r = write_pipe[0],
                .write_pipe_w = write_pipe[1],
                .closed = false,
                .slot = undefined,
                .send_mutex = .{},
            };

            for (0..capacity) |_| {
                writeToken(inner.write_pipe_w);
            }

            return .{ .inner = inner };
        }

        pub fn deinit(self: *Self) void {
            const inner = self.inner;
            std.posix.close(inner.read_pipe_r);
            std.posix.close(inner.read_pipe_w);
            std.posix.close(inner.write_pipe_r);
            std.posix.close(inner.write_pipe_w);
            if (inner.capacity > 0) inner.allocator.free(inner.ring);
            inner.allocator.destroy(inner);
        }

        pub fn close(self: *Self) void {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();
            self.inner.closed = true;
            writeToken(self.inner.read_pipe_w);
            writeToken(self.inner.write_pipe_w);
        }

        pub fn send(self: *Self, value: T) !channel.SendResult() {
            if (self.inner.capacity == 0)
                return self.sendUnbuffered(value);
            return self.sendBuffered(value);
        }

        pub fn recv(self: *Self) !channel.RecvResult(T) {
            if (self.inner.capacity == 0)
                return self.recvUnbuffered();
            return self.recvBuffered();
        }

        fn sendBuffered(self: *Self, value: T) !channel.SendResult() {
            waitFd(self.inner.write_pipe_r);
            readToken(self.inner.write_pipe_r);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.closed) {
                writeToken(self.inner.write_pipe_w);
                return .{ .ok = false };
            }

            self.inner.ring[self.inner.tail] = value;
            self.inner.tail = (self.inner.tail + 1) % self.inner.capacity;
            self.inner.len += 1;
            writeToken(self.inner.read_pipe_w);
            return .{ .ok = true };
        }

        fn recvBuffered(self: *Self) !channel.RecvResult(T) {
            waitFd(self.inner.read_pipe_r);
            readToken(self.inner.read_pipe_r);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.len == 0) {
                writeToken(self.inner.read_pipe_w);
                return .{ .value = undefined, .ok = false };
            }

            const value = self.inner.ring[self.inner.head];
            self.inner.head = (self.inner.head + 1) % self.inner.capacity;
            self.inner.len -= 1;
            writeToken(self.inner.write_pipe_w);
            return .{ .value = value, .ok = true };
        }

        fn sendUnbuffered(self: *Self, value: T) !channel.SendResult() {
            self.inner.send_mutex.lock();
            defer self.inner.send_mutex.unlock();

            {
                self.inner.mutex.lock();
                defer self.inner.mutex.unlock();
                if (self.inner.closed) return .{ .ok = false };
                self.inner.slot = value;
            }

            writeToken(self.inner.read_pipe_w);

            waitFd(self.inner.write_pipe_r);
            readToken(self.inner.write_pipe_r);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();
            if (self.inner.closed) {
                writeToken(self.inner.write_pipe_w);
                return .{ .ok = false };
            }
            return .{ .ok = true };
        }

        fn recvUnbuffered(self: *Self) !channel.RecvResult(T) {
            waitFd(self.inner.read_pipe_r);
            readToken(self.inner.read_pipe_r);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.closed) {
                writeToken(self.inner.read_pipe_w);
                return .{ .value = undefined, .ok = false };
            }

            const value = self.inner.slot;
            writeToken(self.inner.write_pipe_w);
            return .{ .value = value, .ok = true };
        }

        fn writeToken(fd: std.posix.fd_t) void {
            const token: [1]u8 = .{1};
            _ = std.posix.write(fd, &token) catch {};
        }

        fn readToken(fd: std.posix.fd_t) void {
            var buf: [1]u8 = undefined;
            _ = std.posix.read(fd, &buf) catch {};
        }

        fn waitFd(fd: std.posix.fd_t) void {
            var fds = [_]std.posix.pollfd{.{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            _ = std.posix.poll(&fds, -1) catch {};
        }
    };
}
