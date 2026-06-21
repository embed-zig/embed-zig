const glib = @import("glib");
const drivers = @import("drivers");

const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const PipelinePoller = @import("../../pipeline/Poller.zig");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();
        const log = grt.std.log.scoped(.zux_touch);

        pub const Error = error{
            InvalidState,
            Unexpected,
        };

        pub const Config = struct {
            source_id: u32,
        };

        touch: drivers.Touch,
        source_id: u32,
        poll_interval: glib.time.duration.Duration = PipelinePoller.default_poll_interval,
        task_options: glib.task.Options = .{ .min_stack_size = 8 * 1024 },
        out: ?Emitter = null,
        state_mu: grt.sync.Mutex = .{},
        running: bool = false,
        async_failed: bool = false,
        last_pressed: ?bool = null,
        last_point_count: usize = 0,
        last_primary: ?drivers.Touch.Point = null,
        task: ?grt.task.Handle = null,

        pub fn init(self: *Self, touch: drivers.Touch, config: Config) PipelinePoller {
            self.* = .{
                .touch = touch,
                .source_id = config.source_id,
            };
            return PipelinePoller.init(Self, self);
        }

        pub fn bindOutput(self: *Self, out: Emitter) void {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            self.out = out;
        }

        pub fn start(self: *Self, config: PipelinePoller.Config) Error!void {
            self.state_mu.lock();
            if (self.running or self.task != null or self.out == null) {
                self.state_mu.unlock();
                return error.InvalidState;
            }
            self.poll_interval = config.poll_interval;
            self.task_options = config.task_options;
            self.running = true;
            self.async_failed = false;
            self.last_pressed = null;
            self.last_point_count = 0;
            self.last_primary = null;
            self.state_mu.unlock();

            const task = grt.task.go(
                "zux/touch/poller",
                self.task_options,
                glib.task.Routine.init(self, Self.run),
            ) catch {
                self.state_mu.lock();
                self.running = false;
                self.state_mu.unlock();
                return error.Unexpected;
            };

            self.state_mu.lock();
            self.task = task;
            self.state_mu.unlock();
            log.info("poller started source={} interval_ns={}", .{ self.source_id, self.poll_interval });
        }

        pub fn stop(self: *Self) void {
            self.state_mu.lock();
            self.running = false;
            const task = self.task;
            self.task = null;
            self.state_mu.unlock();

            if (task) |t| {
                t.join();
            }
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn isRunning(self: *Self) bool {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            return self.running;
        }

        pub fn hasFailed(self: *Self) bool {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            return self.async_failed;
        }

        fn run(self: *Self) void {
            while (true) {
                const snapshot = blk: {
                    self.state_mu.lock();
                    defer self.state_mu.unlock();
                    if (!self.running) return;

                    break :blk .{
                        .out = self.out orelse {
                            self.async_failed = true;
                            self.running = false;
                            return;
                        },
                        .source_id = self.source_id,
                        .poll_interval = self.poll_interval,
                    };
                };

                self.pollOnce(snapshot.out, snapshot.source_id) catch |err| {
                    log.err("poll failed source={} err={s}", .{ snapshot.source_id, @errorName(err) });
                    self.failAsync();
                };

                if (snapshot.poll_interval > 0) {
                    grt.time.sleep(snapshot.poll_interval);
                }
            }
        }

        fn pollOnce(self: *Self, out: Emitter, source_id: u32) !void {
            var points: [drivers.Touch.max_points]drivers.Touch.Point = undefined;
            const sample = try self.touch.read(points[0..]);
            const pressed = sample.len != 0;
            const primary = if (pressed) sample[0] else null;

            self.state_mu.lock();
            const unchanged = self.last_pressed != null and
                self.last_pressed.? == pressed and
                self.last_point_count == sample.len and
                pointEqual(self.last_primary, primary);
            if (unchanged) {
                self.state_mu.unlock();
                return;
            }
            self.last_pressed = pressed;
            self.last_point_count = sample.len;
            self.last_primary = primary;
            self.state_mu.unlock();

            log.info("emit raw_touch source={} pressed={} count={} x={} y={}", .{
                source_id,
                pressed,
                sample.len,
                if (primary) |point| point.x else 0,
                if (primary) |point| point.y else 0,
            });

            try out.emit(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{
                    .raw_touch = .{
                        .source_id = source_id,
                        .pressed = pressed,
                        .point_count = sample.len,
                        .id = if (primary) |point| point.id else 0,
                        .x = if (primary) |point| point.x else 0,
                        .y = if (primary) |point| point.y else 0,
                        .pressure = if (primary) |point| point.pressure else null,
                    },
                },
            });
        }

        fn failAsync(self: *Self) void {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            self.async_failed = true;
        }
    };
}

fn pointEqual(a: ?drivers.Touch.Point, b: ?drivers.Touch.Point) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.id == b.?.id and
        a.?.x == b.?.x and
        a.?.y == b.?.y and
        a.?.pressure == b.?.pressure;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const PollerType = make(grt);

    const TestCase = struct {
        const TouchImpl = struct {
            samples: []const []const drivers.Touch.Point,
            index: usize = 0,

            pub fn read(self: *@This(), points: []drivers.Touch.Point) !usize {
                const sample_index = @min(self.index, self.samples.len - 1);
                const sample = self.samples[sample_index];
                self.index += 1;
                for (sample, 0..) |point, i| {
                    points[i] = point;
                }
                return sample.len;
            }
        };

        const Sink = struct {
            emitted: usize = 0,
            last: ?Message.Event = null,

            pub fn emit(self: *@This(), message: Message) !void {
                self.emitted += 1;
                self.last = message.body;
            }
        };

        fn emitsOnlyChangedTouchSamples() !void {
            const release: []const drivers.Touch.Point = &.{};
            const press: []const drivers.Touch.Point = &.{.{ .id = 7, .x = 12, .y = 34, .pressure = 56 }};
            const move: []const drivers.Touch.Point = &.{.{ .id = 7, .x = 20, .y = 40, .pressure = 60 }};
            const samples = [_][]const drivers.Touch.Point{
                release,
                release,
                press,
                press,
                move,
                release,
            };
            var impl = TouchImpl{ .samples = samples[0..] };
            const touch = drivers.Touch.init(&impl);
            var poller: PollerType = undefined;
            _ = poller.init(touch, .{ .source_id = 91 });
            var sink = Sink{};
            const out = Emitter.init(&sink);

            try poller.pollOnce(out, 91);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.emitted);
            try grt.std.testing.expect(!sink.last.?.raw_touch.pressed);

            try poller.pollOnce(out, 91);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.emitted);

            try poller.pollOnce(out, 91);
            try grt.std.testing.expectEqual(@as(usize, 2), sink.emitted);
            try grt.std.testing.expect(sink.last.?.raw_touch.pressed);
            try grt.std.testing.expectEqual(@as(u16, 12), sink.last.?.raw_touch.x);

            try poller.pollOnce(out, 91);
            try grt.std.testing.expectEqual(@as(usize, 2), sink.emitted);

            try poller.pollOnce(out, 91);
            try grt.std.testing.expectEqual(@as(usize, 3), sink.emitted);
            try grt.std.testing.expectEqual(@as(u16, 20), sink.last.?.raw_touch.x);

            try poller.pollOnce(out, 91);
            try grt.std.testing.expectEqual(@as(usize, 4), sink.emitted);
            try grt.std.testing.expect(!sink.last.?.raw_touch.pressed);
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

            TestCase.emitsOnlyChangedTouchSamples() catch |err| {
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
