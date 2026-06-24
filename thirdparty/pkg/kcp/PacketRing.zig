const glib = @import("glib");

pub fn make(comptime grt: type) type {
    const std = grt.std;
    const Mutex = grt.sync.Mutex;
    const Condition = grt.sync.Condition;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mutex: Mutex = .{},
        can_read: Condition = .{},
        can_write: Condition = .{},
        storage: []u8,
        lens: []usize,
        packet_capacity: usize,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, ring_capacity: usize, packet_capacity: usize) !Self {
            if (ring_capacity == 0) return error.PacketRingInvalidCapacity;
            if (packet_capacity == 0) return error.PacketRingInvalidPacketCapacity;
            const storage = try allocator.alloc(u8, ring_capacity * packet_capacity);
            errdefer allocator.free(storage);
            const lens = try allocator.alloc(usize, ring_capacity);
            errdefer allocator.free(lens);
            @memset(lens, 0);
            return .{
                .allocator = allocator,
                .storage = storage,
                .lens = lens,
                .packet_capacity = packet_capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.lens);
            self.allocator.free(self.storage);
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
            return self.lens.len;
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

        pub fn tryPush(self: *Self, packet: []const u8) !bool {
            if (packet.len > self.packet_capacity) return error.PacketRingPacketTooLarge;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;
            if (self.len == self.ringCapacity()) return false;
            self.pushLocked(packet);
            return true;
        }

        pub fn pushBlocking(self: *Self, packet: []const u8) !void {
            if (packet.len > self.packet_capacity) return error.PacketRingPacketTooLarge;
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == self.ringCapacity() and !self.closed) {
                self.can_write.wait(&self.mutex);
            }
            if (self.closed) return error.Closed;
            self.pushLocked(packet);
        }

        pub fn tryPop(self: *Self, out: []u8) !?usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == 0) {
                if (self.closed) return error.Closed;
                return null;
            }
            return try self.popLocked(out);
        }

        pub fn popBlocking(self: *Self, out: []u8) !usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == 0 and !self.closed) {
                self.can_read.wait(&self.mutex);
            }
            if (self.len == 0) return error.Closed;
            return self.popLocked(out);
        }

        fn pushLocked(self: *Self, packet: []const u8) void {
            const start = self.tail * self.packet_capacity;
            @memcpy(self.storage[start .. start + packet.len], packet);
            self.lens[self.tail] = packet.len;
            self.tail = (self.tail + 1) % self.ringCapacity();
            self.len += 1;
            self.can_read.signal();
        }

        fn popLocked(self: *Self, out: []u8) !usize {
            const packet_len = self.lens[self.head];
            if (out.len < packet_len) return error.PacketRingOutputTooSmall;
            const start = self.head * self.packet_capacity;
            @memcpy(out[0..packet_len], self.storage[start .. start + packet_len]);
            self.lens[self.head] = 0;
            self.head = (self.head + 1) % self.ringCapacity();
            self.len -= 1;
            self.can_write.signal();
            return packet_len;
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 128 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: grt.std.mem.Allocator) !void {
            const std = grt.std;
            const Ring = make(grt);

            var ring = try Ring.init(allocator, 2, 8);
            defer ring.deinit();

            try std.testing.expect(try ring.tryPush("ab"));
            try std.testing.expect(try ring.tryPush("cde"));
            try std.testing.expect(!try ring.tryPush("fg"));

            var out: [8]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 2), (try ring.tryPop(&out)).?);
            try std.testing.expectEqualStrings("ab", out[0..2]);
            try std.testing.expect(try ring.tryPush("fg"));
            try std.testing.expectEqual(@as(usize, 3), (try ring.tryPop(&out)).?);
            try std.testing.expectEqualStrings("cde", out[0..3]);
            try std.testing.expectEqual(@as(usize, 2), (try ring.tryPop(&out)).?);
            try std.testing.expectEqualStrings("fg", out[0..2]);
            try std.testing.expectEqual(@as(?usize, null), try ring.tryPop(&out));

            ring.close();
            try std.testing.expectError(error.Closed, ring.tryPush("x"));
            try std.testing.expectError(error.Closed, ring.tryPop(&out));
        }
    }.run);
}
