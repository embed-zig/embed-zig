//! audio.mixer.RingBuffer — blocking PCM sample ring buffer.

const glib = @import("glib");

pub fn make(comptime grt: type) type {
    const Allocator = glib.std.mem.Allocator;
    const Thread = grt.std.Thread;

    return struct {
        allocator: Allocator,
        items: []i16,
        head: usize = 0,
        len: usize = 0,
        write_closed: bool = false,
        has_error: bool = false,
        mutex: Thread.Mutex = .{},
        cond: Thread.Condition = .{},

        pub fn init(allocator: Allocator, capacity: usize) !@This() {
            return .{
                .allocator = allocator,
                .items = try allocator.alloc(i16, capacity),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.items);
            self.* = undefined;
        }

        pub fn write(self: *@This(), samples: []const i16) error{Closed}!void {
            if (samples.len == 0) return;

            var offset: usize = 0;
            self.mutex.lock();
            defer self.mutex.unlock();

            while (offset < samples.len) {
                while (self.len >= self.items.len and !self.write_closed and !self.has_error) {
                    self.cond.wait(&self.mutex);
                }

                if (self.write_closed or self.has_error) return error.Closed;

                const space = self.items.len - self.len;
                const n = @min(samples.len - offset, space);
                self.writeLocked(samples[offset .. offset + n]);
                offset += n;
            }
        }

        pub fn writeDroppingOldest(self: *@This(), samples: []const i16) void {
            if (samples.len == 0) return;

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.write_closed or self.has_error) return;

            var in = samples;
            if (in.len >= self.items.len) {
                in = in[in.len - self.items.len ..];
                self.head = 0;
                self.len = 0;
            } else if (self.len + in.len > self.items.len) {
                self.consumeLocked(self.len + in.len - self.items.len);
            }

            self.writeLocked(in);
            self.cond.broadcast();
        }

        pub fn closeWrite(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.write_closed = true;
            self.cond.broadcast();
        }

        pub fn closeWithError(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.write_closed = true;
            self.has_error = true;
            self.head = 0;
            self.len = 0;
            self.cond.broadcast();
        }

        pub fn isDrained(self: *@This()) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.write_closed and self.len == 0;
        }

        pub fn mixInto(self: *@This(), out: []i16, gain: f32) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            const n = @min(out.len, self.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const sample = self.peekLocked(i);
                const scaled = @as(f32, @floatFromInt(sample)) * gain;
                const mixed = @as(f32, @floatFromInt(out[i])) + scaled;
                out[i] = clampToI16(mixed);
            }
            self.consumeLocked(n);
            if (n > 0) self.cond.broadcast();
            return n;
        }

        fn writeLocked(self: *@This(), samples: []const i16) void {
            var offset: usize = 0;
            while (offset < samples.len) {
                const tail = (self.head + self.len) % self.items.len;
                const contiguous = @min(samples.len - offset, self.items.len - tail);
                @memcpy(self.items[tail .. tail + contiguous], samples[offset .. offset + contiguous]);
                self.len += contiguous;
                offset += contiguous;
            }
        }

        fn peekLocked(self: *@This(), index: usize) i16 {
            return self.items[(self.head + index) % self.items.len];
        }

        fn consumeLocked(self: *@This(), n: usize) void {
            const actual = @min(n, self.len);
            if (actual == 0) return;
            self.head = (self.head + actual) % self.items.len;
            self.len -= actual;
            if (self.len == 0) self.head = 0;
        }
    };
}

fn clampToI16(value: f32) i16 {
    if (value != value) return 0;
    if (value > 32767.0) return 32767;
    if (value < -32768.0) return -32768;
    return @intFromFloat(value);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Buffer = make(grt);

    const TestCase = struct {
        fn mixIntoAppliesGainAndClamps() !void {
            var buffer = try Buffer.init(grt.std.testing.allocator, 4);
            defer buffer.deinit();

            try buffer.write(&.{ 30000, -30000 });

            var out = [_]i16{ 30000, -30000 };
            const n = buffer.mixInto(&out, 1.0);
            try grt.std.testing.expectEqual(@as(usize, 2), n);
            try grt.std.testing.expectEqualSlices(i16, &.{ 32767, -32768 }, out[0..2]);
        }

        fn closeWriteDrainsThenReportsDrained() !void {
            var buffer = try Buffer.init(grt.std.testing.allocator, 4);
            defer buffer.deinit();

            try buffer.write(&.{ 7, 8 });
            buffer.closeWrite();
            try grt.std.testing.expect(!buffer.isDrained());

            var out: [4]i16 = @splat(0);
            const n = buffer.mixInto(&out, 1.0);
            try grt.std.testing.expectEqual(@as(usize, 2), n);
            try grt.std.testing.expectEqualSlices(i16, &.{ 7, 8 }, out[0..2]);
            try grt.std.testing.expect(buffer.isDrained());
        }

        fn closeWithErrorUnblocksBlockedWriter() !void {
            const Thread = grt.std.Thread;
            const ns_per_ms = grt.std.time.ns_per_ms;

            var buffer = try Buffer.init(grt.std.testing.allocator, 2);
            defer buffer.deinit();

            try buffer.write(&.{ 1, 2 });

            const State = struct {
                buffer: *Buffer,
                result: ?anyerror = null,
            };

            var state = State{ .buffer = &buffer };
            const worker = try Thread.spawn(.{}, struct {
                fn run(s: *State) void {
                    s.buffer.write(&.{ 3, 4 }) catch |err| {
                        s.result = err;
                        return;
                    };
                }
            }.run, .{&state});

            Thread.sleep(10 * ns_per_ms);
            buffer.closeWithError();
            worker.join();

            try grt.std.testing.expectEqual(error.Closed, state.result.?);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.mixIntoAppliesGainAndClamps() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.closeWriteDrainsThenReportsDrained() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.closeWithErrorUnblocksBlockedWriter() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
