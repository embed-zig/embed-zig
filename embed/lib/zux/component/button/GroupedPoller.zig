const glib = @import("glib");
const drivers = @import("drivers");

const Emitter = @import("../../pipeline/Emitter.zig");
const Poller = @import("../../pipeline/Poller.zig");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();
        const log = grt.std.log.scoped(.button_poller);

        pub const Error = error{
            InvalidState,
            Unexpected,
        };

        pub const Config = struct {
            source_id: u32,
        };

        button: drivers.button.Grouped,
        source_id: u32,
        poll_interval: glib.time.duration.Duration = Poller.default_poll_interval,
        task_options: glib.task.Options = .{ .min_stack_size = 8 * 1024 },
        out: ?Emitter = null,
        state_mu: grt.sync.Mutex = .{},
        running: bool = false,
        async_failed: bool = false,
        has_last_button_id: bool = false,
        last_button_id: ?u32 = null,
        task: ?grt.task.Handle = null,

        pub fn init(self: *Self, button: drivers.button.Grouped, config: Config) Poller {
            self.* = .{
                .button = button,
                .source_id = config.source_id,
            };
            return Poller.init(Self, self);
        }

        pub fn bindOutput(self: *Self, out: Emitter) void {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            self.out = out;
        }

        pub fn start(self: *Self, config: Poller.Config) Error!void {
            self.state_mu.lock();
            if (self.running or self.task != null or self.out == null) {
                self.state_mu.unlock();
                return error.InvalidState;
            }
            self.poll_interval = config.poll_interval;
            self.task_options = config.task_options;
            self.running = true;
            self.async_failed = false;
            self.has_last_button_id = false;
            self.last_button_id = null;
            self.state_mu.unlock();

            const task = grt.task.go(
                "zux/button/grouped",
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
            const button_id = try self.button.pressedButtonId();
            self.state_mu.lock();
            const had_last_button_id = self.has_last_button_id;
            const last_button_id = self.last_button_id;
            if (had_last_button_id and last_button_id == button_id) {
                self.state_mu.unlock();
                return;
            }
            self.has_last_button_id = true;
            self.last_button_id = button_id;
            self.state_mu.unlock();

            if (!had_last_button_id) {
                if (button_id == null) return;
                try emitRawGroupedButton(out, source_id, button_id, true);
                return;
            }

            if (last_button_id) |previous_button_id| {
                try emitRawGroupedButton(out, source_id, previous_button_id, false);
            }

            if (button_id) |next_button_id| {
                try emitRawGroupedButton(out, source_id, next_button_id, true);
            }
        }

        fn emitRawGroupedButton(out: Emitter, source_id: u32, button_id: ?u32, pressed: bool) !void {
            const now = grt.time.instant.now();
            log.info("raw grouped button source_id={} button_id={?} pressed={} timestamp={}", .{ source_id, button_id, pressed, now });
            try out.emit(.{
                .origin = .source,
                .timestamp = now,
                .body = .{
                    .raw_grouped_button = .{
                        .source_id = source_id,
                        .button_id = button_id,
                        .pressed = pressed,
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
