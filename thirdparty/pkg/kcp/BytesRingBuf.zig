const glib = @import("glib");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();
        const Allocator = grt.std.mem.Allocator;
        const Mutex = grt.sync.Mutex;
        const Condition = grt.sync.Condition;

        buf: []u8 = &.{},
        head: usize = 0,
        len_value: usize = 0,
        write_reserved: bool = false,
        mu: Mutex = .{},
        cond: Condition = .{},

        pub const WriteReservation = struct {
            buf: []u8,
        };

        pub fn init(self: *Self, allocator: Allocator, capacity: usize) !void {
            if (capacity == 0) return error.InvalidCapacity;
            self.* = .{
                .buf = try allocator.alloc(u8, capacity),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn write(self: *Self, src: []const u8, timeout: ?glib.time.duration.Duration) error{TimedOut}!usize {
            if (src.len == 0) return 0;
            self.mu.lock();
            defer self.mu.unlock();
            try self.waitForSpaceLocked(timeout);
            return self.writeNoWaitLocked(src);
        }

        pub fn writeNoWait(self: *Self, src: []const u8) usize {
            if (src.len == 0) return 0;
            self.mu.lock();
            defer self.mu.unlock();
            return self.writeNoWaitLocked(src);
        }

        pub fn read(self: *Self, out: []u8) usize {
            self.mu.lock();
            defer self.mu.unlock();
            const n = @min(out.len, self.len_value);
            if (n == 0) return 0;
            readLocked(self.buf, &self.head, &self.len_value, out[0..n]);
            self.cond.broadcast();
            return n;
        }

        pub fn readSpan(self: *Self, limit: usize) []const u8 {
            self.mu.lock();
            defer self.mu.unlock();
            const n = @min(@min(self.len_value, limit), self.buf.len - self.head);
            return self.buf[self.head..][0..n];
        }

        pub fn discard(self: *Self, n: usize) void {
            self.mu.lock();
            defer self.mu.unlock();
            const count = @min(n, self.len_value);
            if (count == 0) return;
            self.head = (self.head + count) % self.buf.len;
            self.len_value -= count;
            self.cond.broadcast();
        }

        pub fn reserveWriteSpan(self: *Self) ?WriteReservation {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.write_reserved) return null;
            if (self.len_value == 0) self.head = 0;
            const space_value = self.spaceLocked();
            if (space_value == 0) return null;
            const tail = (self.head + self.len_value) % self.buf.len;
            const n = @min(space_value, self.buf.len - tail);
            self.write_reserved = true;
            return .{ .buf = self.buf[tail..][0..n] };
        }

        pub fn commitWriteSpan(self: *Self, n: usize) void {
            self.mu.lock();
            defer self.mu.unlock();
            if (!self.write_reserved) return;
            self.len_value += @min(n, self.spaceLocked());
            self.write_reserved = false;
            self.cond.broadcast();
        }

        pub fn releaseWriteSpan(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.write_reserved = false;
            self.cond.broadcast();
        }

        pub fn len(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.len_value;
        }

        pub fn space(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.spaceLocked();
        }

        pub fn contiguousWriteCapacity(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.len_value == 0) return self.buf.len;
            const space_value = self.spaceLocked();
            if (space_value == 0) return 0;
            const tail = (self.head + self.len_value) % self.buf.len;
            return @min(space_value, self.buf.len - tail);
        }

        pub fn wakeAll(self: *Self) void {
            self.cond.broadcast();
        }

        fn writeNoWaitLocked(self: *Self, src: []const u8) usize {
            if (self.write_reserved) return 0;
            const n = @min(src.len, self.spaceLocked());
            if (n == 0) return 0;
            if (self.len_value == 0) self.head = 0;
            writeLocked(self.buf, self.head, self.len_value, src[0..n]);
            self.len_value += n;
            self.cond.broadcast();
            return n;
        }

        fn waitForSpaceLocked(self: *Self, timeout: ?glib.time.duration.Duration) error{TimedOut}!void {
            if (self.spaceLocked() > 0 and !self.write_reserved) return;
            const started = grt.time.instant.now();
            while (self.spaceLocked() == 0 or self.write_reserved) {
                if (timeout) |duration| {
                    const elapsed = glib.time.instant.sub(grt.time.instant.now(), started);
                    if (elapsed >= duration) return error.TimedOut;
                    const remaining: u64 = @intCast(duration - elapsed);
                    self.cond.timedWait(&self.mu, @min(remaining, 10 * glib.time.duration.MilliSecond)) catch {};
                } else {
                    self.cond.wait(&self.mu);
                }
            }
        }

        fn spaceLocked(self: *const Self) usize {
            return self.buf.len - self.len_value;
        }
    };
}

fn writeLocked(ring: []u8, head: usize, len_value: usize, src: []const u8) void {
    if (src.len == 0) return;
    const tail = (head + len_value) % ring.len;
    const first = @min(src.len, ring.len - tail);
    @memcpy(ring[tail..][0..first], src[0..first]);
    if (first < src.len) {
        @memcpy(ring[0 .. src.len - first], src[first..]);
    }
}

fn readLocked(ring: []const u8, head: *usize, len_value: *usize, out: []u8) void {
    if (out.len == 0) return;
    const first = @min(out.len, ring.len - head.*);
    @memcpy(out[0..first], ring[head.*..][0..first]);
    if (first < out.len) {
        @memcpy(out[first..], ring[0 .. out.len - first]);
    }
    head.* = (head.* + out.len) % ring.len;
    len_value.* -= out.len;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 32 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: grt.std.mem.Allocator) !void {
            const std = grt.std;
            const Ring = make(grt);

            var ring: Ring = .{};
            try std.testing.expectError(error.InvalidCapacity, ring.init(allocator, 0));
            try ring.init(allocator, 8);
            defer ring.deinit(allocator);

            try std.testing.expectEqual(@as(usize, 4), try ring.write("abcd", null));
            var out: [3]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 3), ring.read(&out));
            try std.testing.expectEqualSlices(u8, "abc", &out);

            try std.testing.expectEqual(@as(usize, 5), try ring.write("efghi", null));
            const span = ring.readSpan(8);
            try std.testing.expectEqualSlices(u8, "defgh", span);
            ring.discard(span.len);
            try std.testing.expectEqual(@as(usize, 1), ring.len());

            const reservation = ring.reserveWriteSpan().?;
            try std.testing.expect(reservation.buf.len > 0);
            @memcpy(reservation.buf[0..1], "j");
            ring.commitWriteSpan(1);
            var final_out: [2]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 2), ring.read(&final_out));
            try std.testing.expectEqualSlices(u8, "ij", &final_out);

            try std.testing.expectEqual(@as(usize, 8), ring.contiguousWriteCapacity());
            try std.testing.expectEqual(@as(usize, 8), ring.writeNoWait("klmnopqrst"));
            try std.testing.expectEqual(@as(usize, 0), ring.writeNoWait("u"));
            var all_out: [8]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 8), ring.read(&all_out));
            try std.testing.expectEqualSlices(u8, "klmnopqr", &all_out);
        }
    }.run);
}
