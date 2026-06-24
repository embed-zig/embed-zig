const glib = @import("glib");

pub fn make(comptime grt: type) type {
    const std = grt.std;
    const Mutex = grt.sync.Mutex;
    const Condition = grt.sync.Condition;
    const duration = glib.time.duration;
    const instant = grt.time.instant;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mutex: Mutex = .{},
        can_read: Condition = .{},
        can_write: Condition = .{},
        buf: []u8,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, ring_capacity: usize) !Self {
            if (ring_capacity == 0) return error.BytesRingInvalidCapacity;
            return .{
                .allocator = allocator,
                .buf = try allocator.alloc(u8, ring_capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.can_read.broadcast();
            self.can_write.broadcast();
        }

        pub fn ringCapacity(self: *const Self) usize {
            return self.buf.len;
        }

        pub fn availableRead(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }

        pub fn availableWrite(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.ringCapacity() - self.len;
        }

        pub fn writeBlocking(self: *Self, bytes: []const u8) !usize {
            return self.writeWithTimeout(bytes, null);
        }

        pub fn writeTimeout(self: *Self, bytes: []const u8, timeout: duration.Duration) !usize {
            return self.writeWithTimeout(bytes, timeout);
        }

        pub fn readBlocking(self: *Self, out: []u8) !usize {
            return self.readWithTimeout(out, null);
        }

        pub fn readTimeout(self: *Self, out: []u8, timeout: duration.Duration) !usize {
            return self.readWithTimeout(out, timeout);
        }

        fn writeWithTimeout(self: *Self, bytes: []const u8, timeout: ?duration.Duration) !usize {
            if (bytes.len == 0) return 0;
            const deadline = makeDeadline(timeout);
            var written: usize = 0;
            while (written < bytes.len) {
                self.mutex.lock();
                while (self.len == self.ringCapacity() and !self.closed) {
                    self.waitForWrite(deadline) catch |err| {
                        self.mutex.unlock();
                        if (written != 0) return written;
                        return err;
                    };
                }
                if (self.closed) {
                    self.mutex.unlock();
                    if (written != 0) return written;
                    return error.Closed;
                }
                const n = self.writeLocked(bytes[written..]);
                self.can_read.signal();
                self.mutex.unlock();
                written += n;
            }
            return written;
        }

        fn readWithTimeout(self: *Self, out: []u8, timeout: ?duration.Duration) !usize {
            if (out.len == 0) return 0;
            const deadline = makeDeadline(timeout);
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == 0 and !self.closed) {
                try self.waitForRead(deadline);
            }
            if (self.len == 0) return error.Closed;
            const n = self.readLocked(out);
            self.can_write.signal();
            return n;
        }

        pub fn tryWrite(self: *Self, bytes: []const u8) !usize {
            if (bytes.len == 0) return 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;
            if (self.len == self.ringCapacity()) return 0;
            const n = self.writeLocked(bytes);
            self.can_read.signal();
            return n;
        }

        pub fn tryRead(self: *Self, out: []u8) !usize {
            if (out.len == 0) return 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == 0) {
                if (self.closed) return error.Closed;
                return 0;
            }
            const n = self.readLocked(out);
            self.can_write.signal();
            return n;
        }

        fn writeLocked(self: *Self, bytes: []const u8) usize {
            const writable = @min(bytes.len, self.ringCapacity() - self.len);
            const first = @min(writable, self.ringCapacity() - self.tail);
            @memcpy(self.buf[self.tail .. self.tail + first], bytes[0..first]);
            const second = writable - first;
            if (second != 0) {
                @memcpy(self.buf[0..second], bytes[first .. first + second]);
            }
            self.tail = (self.tail + writable) % self.ringCapacity();
            self.len += writable;
            return writable;
        }

        fn readLocked(self: *Self, out: []u8) usize {
            const readable = @min(out.len, self.len);
            const first = @min(readable, self.ringCapacity() - self.head);
            @memcpy(out[0..first], self.buf[self.head .. self.head + first]);
            const second = readable - first;
            if (second != 0) {
                @memcpy(out[first .. first + second], self.buf[0..second]);
            }
            self.head = (self.head + readable) % self.ringCapacity();
            self.len -= readable;
            return readable;
        }

        fn makeDeadline(timeout: ?duration.Duration) ?instant.Time {
            const value = timeout orelse return null;
            return instant.add(instant.now(), value);
        }

        fn waitForWrite(self: *Self, deadline: ?instant.Time) error{Timeout}!void {
            const value = deadline orelse {
                self.can_write.wait(&self.mutex);
                return;
            };
            const remaining = instant.sub(value, instant.now());
            if (remaining <= 0) return error.Timeout;
            self.can_write.timedWait(&self.mutex, @intCast(remaining)) catch return error.Timeout;
        }

        fn waitForRead(self: *Self, deadline: ?instant.Time) error{Timeout}!void {
            const value = deadline orelse {
                self.can_read.wait(&self.mutex);
                return;
            };
            const remaining = instant.sub(value, instant.now());
            if (remaining <= 0) return error.Timeout;
            self.can_read.timedWait(&self.mutex, @intCast(remaining)) catch return error.Timeout;
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 128 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: grt.std.mem.Allocator) !void {
            const std = grt.std;
            const Ring = make(grt);

            var ring = try Ring.init(allocator, 5);
            defer ring.deinit();

            try std.testing.expectEqual(@as(usize, 5), try ring.tryWrite("abcde"));
            try std.testing.expectEqual(@as(usize, 0), try ring.tryWrite("x"));

            var out: [8]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 2), try ring.tryRead(out[0..2]));
            try std.testing.expectEqualStrings("ab", out[0..2]);
            try std.testing.expectEqual(@as(usize, 2), try ring.tryWrite("fg"));
            try std.testing.expectEqual(@as(usize, 5), try ring.tryRead(&out));
            try std.testing.expectEqualStrings("cdefg", out[0..5]);
            try std.testing.expectEqual(@as(usize, 0), try ring.tryRead(&out));

            try std.testing.expectEqual(@as(usize, 3), try ring.writeBlocking("xyz"));
            try std.testing.expectEqual(@as(usize, 3), try ring.readBlocking(&out));
            try std.testing.expectEqualStrings("xyz", out[0..3]);

            try std.testing.expectEqual(@as(usize, 5), try ring.tryWrite("abcde"));
            try std.testing.expectEqual(@as(usize, 0), try ring.tryWrite("x"));
            try std.testing.expectEqual(@as(usize, 2), try ring.readTimeout(out[0..2], glib.time.duration.MilliSecond));
            try std.testing.expectEqual(@as(usize, 2), try ring.writeTimeout("fg", glib.time.duration.MilliSecond));
            try std.testing.expectEqualStrings("ab", out[0..2]);
            try std.testing.expectEqual(@as(usize, 5), try ring.tryRead(&out));
            try std.testing.expectEqualStrings("cdefg", out[0..5]);

            try std.testing.expectEqual(@as(usize, 4), try ring.tryWrite("abcd"));
            try std.testing.expectEqual(@as(usize, 1), try ring.writeTimeout("ef", glib.time.duration.MilliSecond));
            try std.testing.expectEqual(@as(usize, 5), try ring.tryRead(&out));
            try std.testing.expectEqualStrings("abcde", out[0..5]);

            ring.close();
            try std.testing.expectError(error.Closed, ring.tryWrite("x"));
            try std.testing.expectError(error.Closed, ring.tryRead(&out));
        }
    }.run);
}
