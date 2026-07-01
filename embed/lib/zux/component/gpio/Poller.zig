const drivers = @import("drivers");
const glib = @import("glib");

const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const PipelinePoller = @import("../../pipeline/Poller.zig");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();
        const log = grt.std.log.scoped(.zux_gpio);

        pub const Error = error{
            InvalidState,
            Unexpected,
        };

        pub const Config = struct {
            source_id: u32,
        };

        gpio: drivers.Gpio,
        source_id: u32,
        poll_interval: glib.time.duration.Duration = PipelinePoller.default_poll_interval,
        task_options: glib.task.Options = .{ .min_stack_size = 8 * 1024 },
        out: ?Emitter = null,
        state_mu: grt.sync.Mutex = .{},
        running: bool = false,
        async_failed: bool = false,
        last_level: ?drivers.Gpio.Level = null,
        task: ?grt.task.Handle = null,

        pub fn init(self: *Self, gpio: drivers.Gpio, config: Config) PipelinePoller {
            self.* = .{
                .gpio = gpio,
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
            self.last_level = null;
            self.state_mu.unlock();

            const task = grt.task.go(
                "zux/gpio/poller",
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
            const level = try self.gpio.read();
            const edge = edgeFromTransition(self.last_level, level);

            self.state_mu.lock();
            if (self.last_level != null and self.last_level.? == level) {
                self.state_mu.unlock();
                return;
            }
            self.last_level = level;
            self.state_mu.unlock();

            log.info("emit raw_gpio_changed source={} edge={s} level={s}", .{
                source_id,
                @tagName(edge),
                @tagName(level),
            });

            try out.emit(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{
                    .raw_gpio_changed = .{
                        .source_id = source_id,
                        .edge = edge,
                        .level = level,
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

fn edgeFromTransition(previous: ?drivers.Gpio.Level, current: drivers.Gpio.Level) drivers.Gpio.Edge {
    const prior = previous orelse return switch (current) {
        .low => .low_level,
        .high => .high_level,
    };
    if (prior == .low and current == .high) return .rising;
    if (prior == .high and current == .low) return .falling;
    return switch (current) {
        .low => .low_level,
        .high => .high_level,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const PollerType = make(grt);

    const TestCase = struct {
        const Pin = struct {
            samples: []const drivers.Gpio.Level,
            index: usize = 0,

            pub fn read(self: *@This()) drivers.Gpio.Error!drivers.Gpio.Level {
                const sample_index = @min(self.index, self.samples.len - 1);
                const level = self.samples[sample_index];
                self.index += 1;
                return level;
            }

            pub fn write(_: *@This(), _: drivers.Gpio.Level) drivers.Gpio.Error!void {}

            pub fn setDirection(_: *@This(), _: drivers.Gpio.Direction) drivers.Gpio.Error!void {}
        };

        const Sink = struct {
            emitted: usize = 0,
            last: ?Message.Event = null,

            pub fn emit(self: *@This(), message: Message) !void {
                self.emitted += 1;
                self.last = message.body;
            }
        };

        fn emitsInitialLevelAndLevelChangesOnly() !void {
            const samples = [_]drivers.Gpio.Level{
                .low,
                .low,
                .high,
                .high,
                .low,
            };
            var pin = Pin{ .samples = samples[0..] };
            const gpio = drivers.Gpio.init(&pin);
            var poller: PollerType = undefined;
            _ = poller.init(gpio, .{ .source_id = 44 });
            var sink = Sink{};
            const out = Emitter.init(&sink);

            try poller.pollOnce(out, 44);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.emitted);
            try grt.std.testing.expectEqual(drivers.Gpio.Edge.low_level, sink.last.?.raw_gpio_changed.edge);
            try grt.std.testing.expectEqual(drivers.Gpio.Level.low, sink.last.?.raw_gpio_changed.level);

            try poller.pollOnce(out, 44);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.emitted);

            try poller.pollOnce(out, 44);
            try grt.std.testing.expectEqual(@as(usize, 2), sink.emitted);
            try grt.std.testing.expectEqual(drivers.Gpio.Edge.rising, sink.last.?.raw_gpio_changed.edge);
            try grt.std.testing.expectEqual(drivers.Gpio.Level.high, sink.last.?.raw_gpio_changed.level);

            try poller.pollOnce(out, 44);
            try grt.std.testing.expectEqual(@as(usize, 2), sink.emitted);

            try poller.pollOnce(out, 44);
            try grt.std.testing.expectEqual(@as(usize, 3), sink.emitted);
            try grt.std.testing.expectEqual(drivers.Gpio.Edge.falling, sink.last.?.raw_gpio_changed.edge);
            try grt.std.testing.expectEqual(drivers.Gpio.Level.low, sink.last.?.raw_gpio_changed.level);
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

            TestCase.emitsInitialLevelAndLevelChangesOnly() catch |err| {
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
