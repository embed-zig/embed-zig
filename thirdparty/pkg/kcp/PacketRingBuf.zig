const glib = @import("glib");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();
        const Allocator = grt.std.mem.Allocator;
        const Mutex = grt.sync.Mutex;
        const Condition = grt.sync.Condition;

        buf: []u8 = &.{},
        lens: []usize = &.{},
        packet_capacity: usize = 0,
        head: usize = 0,
        len_value: usize = 0,
        write_reserved: bool = false,
        mu: Mutex = .{},
        cond: Condition = .{},

        pub const WriteReservation = struct {
            index: usize,
            buf: []u8,
        };

        pub fn init(self: *Self, allocator: Allocator, slots: usize, packet_capacity: usize) !void {
            if (slots == 0 or packet_capacity == 0) return error.InvalidCapacity;
            const buf = try allocator.alloc(u8, slots * packet_capacity);
            errdefer allocator.free(buf);
            const lens = try allocator.alloc(usize, slots);
            self.* = .{
                .buf = buf,
                .lens = lens,
                .packet_capacity = packet_capacity,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.lens);
            allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn reserveWrite(self: *Self) ?WriteReservation {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.write_reserved) return null;
            if (self.len_value >= self.lens.len) return null;
            const index = (self.head + self.len_value) % self.lens.len;
            self.write_reserved = true;
            return .{
                .index = index,
                .buf = self.slot(index),
            };
        }

        pub fn commitWrite(self: *Self, reservation: WriteReservation, packet_len: usize) bool {
            self.mu.lock();
            defer self.mu.unlock();
            self.write_reserved = false;
            const expected = (self.head + self.len_value) % self.lens.len;
            if (reservation.index != expected or self.len_value >= self.lens.len) {
                self.cond.broadcast();
                return false;
            }
            self.lens[reservation.index] = @min(packet_len, self.packet_capacity);
            self.len_value += 1;
            self.cond.broadcast();
            return true;
        }

        pub fn releaseWrite(self: *Self) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.write_reserved = false;
            self.cond.broadcast();
        }

        pub fn push(self: *Self, packet: []const u8, timeout: ?glib.time.duration.Duration) error{ TimedOut, PacketTooLarge }!void {
            if (packet.len > self.packet_capacity) return error.PacketTooLarge;
            self.mu.lock();
            defer self.mu.unlock();
            try self.waitForSpaceLocked(timeout);
            const index = (self.head + self.len_value) % self.lens.len;
            @memcpy(self.slot(index)[0..packet.len], packet);
            self.lens[index] = packet.len;
            self.len_value += 1;
            self.cond.broadcast();
        }

        pub fn pop(self: *Self, out: []u8, timeout: ?glib.time.duration.Duration) error{TimedOut}!usize {
            self.mu.lock();
            defer self.mu.unlock();
            try self.waitForPacketLocked(timeout);
            if (self.len_value == 0) return 0;
            const index = self.head;
            const n = @min(self.lens[index], out.len);
            @memcpy(out[0..n], self.slot(index)[0..n]);
            self.head = (self.head + 1) % self.lens.len;
            self.len_value -= 1;
            self.cond.broadcast();
            return n;
        }

        pub fn popNoWait(self: *Self, out: []u8) ?usize {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.len_value == 0) return null;
            const index = self.head;
            const n = @min(self.lens[index], out.len);
            @memcpy(out[0..n], self.slot(index)[0..n]);
            self.head = (self.head + 1) % self.lens.len;
            self.len_value -= 1;
            self.cond.broadcast();
            return n;
        }

        pub fn len(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.len_value;
        }

        pub fn space(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.lens.len - self.len_value;
        }

        pub fn waitForSpace(self: *Self, timeout: ?glib.time.duration.Duration) error{TimedOut}!void {
            self.mu.lock();
            defer self.mu.unlock();
            try self.waitForSpaceLocked(timeout);
        }

        pub fn wakeAll(self: *Self) void {
            self.cond.broadcast();
        }

        fn waitForSpaceLocked(self: *Self, timeout: ?glib.time.duration.Duration) error{TimedOut}!void {
            if (self.len_value < self.lens.len and !self.write_reserved) return;
            const started = grt.time.instant.now();
            while (self.len_value >= self.lens.len or self.write_reserved) {
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

        fn waitForPacketLocked(self: *Self, timeout: ?glib.time.duration.Duration) error{TimedOut}!void {
            if (self.len_value > 0) return;
            const started = grt.time.instant.now();
            while (self.len_value == 0) {
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

        fn slot(self: *Self, index: usize) []u8 {
            const start = index * self.packet_capacity;
            return self.buf[start..][0..self.packet_capacity];
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 32 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: grt.std.mem.Allocator) !void {
            const std = grt.std;
            const Ring = make(grt);

            var ring: Ring = .{};
            try std.testing.expectError(error.InvalidCapacity, ring.init(allocator, 0, 8));
            try std.testing.expectError(error.InvalidCapacity, ring.init(allocator, 2, 0));
            try ring.init(allocator, 2, 8);
            defer ring.deinit(allocator);

            try std.testing.expectError(error.PacketTooLarge, ring.push("abcdefghi", null));
            try ring.push("abcd", null);
            const reservation = ring.reserveWrite().?;
            @memcpy(reservation.buf[0..2], "ef");
            try std.testing.expect(ring.commitWrite(reservation, 2));
            try std.testing.expectEqual(@as(usize, 2), ring.len());
            try std.testing.expectEqual(@as(usize, 0), ring.space());
            try std.testing.expect(ring.reserveWrite() == null);
            try std.testing.expectError(error.TimedOut, ring.push("gh", 0));

            var out: [8]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 4), try ring.pop(&out, null));
            try std.testing.expectEqualSlices(u8, "abcd", out[0..4]);
            try ring.push("gh", null);
            try std.testing.expectEqual(@as(usize, 2), ring.popNoWait(&out).?);
            try std.testing.expectEqualSlices(u8, "ef", out[0..2]);
            try std.testing.expectEqual(@as(usize, 2), ring.popNoWait(&out).?);
            try std.testing.expectEqualSlices(u8, "gh", out[0..2]);
            try std.testing.expectEqual(@as(?usize, null), ring.popNoWait(&out));
        }
    }.run);
}
