const glib = @import("glib");
const drivers = @import("drivers");

const Emitter = @import("../../pipeline/Emitter.zig");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{
            InvalidState,
            Unexpected,
        };

        pub const default_poll_interval: glib.time.duration.Duration = 10 * glib.time.duration.MilliSecond;

        pub const Config = struct {
            source_id: u32,
            poll_interval: glib.time.duration.Duration = default_poll_interval,
            task_options: glib.task.Options = .{ .min_stack_size = 8 * 1024 },
        };

        imu: drivers.imu,
        source_id: u32,
        poll_interval: glib.time.duration.Duration = default_poll_interval,
        task_options: glib.task.Options = .{ .min_stack_size = 8 * 1024 },
        out: ?Emitter = null,
        state_mu: grt.sync.Mutex = .{},
        running: bool = false,
        async_failed: bool = false,
        task: ?grt.task.Handle = null,

        pub fn init(imu: drivers.imu, config: Config) Self {
            return .{
                .imu = imu,
                .source_id = config.source_id,
                .poll_interval = config.poll_interval,
                .task_options = config.task_options,
            };
        }

        pub fn bindOutput(self: *Self, out: Emitter) void {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            self.out = out;
        }

        pub fn start(self: *Self) Error!void {
            self.state_mu.lock();
            if (self.running or self.task != null or self.out == null) {
                self.state_mu.unlock();
                return error.InvalidState;
            }
            self.running = true;
            self.async_failed = false;
            self.state_mu.unlock();

            const task = grt.task.go(
                "zux/imu/poller",
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

                self.pollOnce(snapshot.out, snapshot.source_id) catch {
                    self.failAsync();
                };

                if (snapshot.poll_interval > 0) {
                    grt.time.sleep(snapshot.poll_interval);
                }
            }
        }

        fn pollOnce(self: *Self, out: Emitter, source_id: u32) !void {
            const sample = try self.imu.read();
            const timestamp = grt.time.instant.now();

            if (sample.accel) |accel| {
                try out.emit(.{
                    .origin = .source,
                    .timestamp = timestamp,
                    .body = .{
                        .raw_imu_accel = .{
                            .source_id = source_id,
                            .x = accel.x,
                            .y = accel.y,
                            .z = accel.z,
                        },
                    },
                });
            }

            if (sample.gyro) |gyro| {
                try out.emit(.{
                    .origin = .source,
                    .timestamp = timestamp,
                    .body = .{
                        .raw_imu_gyro = .{
                            .source_id = source_id,
                            .x = gyro.x,
                            .y = gyro.y,
                            .z = gyro.z,
                        },
                    },
                });
            }
        }

        fn failAsync(self: *Self) void {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            self.async_failed = true;
        }
    };
}
