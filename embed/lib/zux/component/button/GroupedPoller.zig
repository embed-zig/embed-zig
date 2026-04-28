const glib = @import("glib");
const drivers = @import("drivers");

const Context = @import("../../event/Context.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Poller = @import("../../pipeline/Poller.zig");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{
            InvalidState,
            Unexpected,
        };

        pub const Config = struct {
            source_id: u32,
            ctx: Context.Type = null,
        };

        button: drivers.button.Grouped,
        source_id: u32,
        poll_interval: glib.time.duration.Duration = Poller.default_poll_interval,
        spawn_config: grt.std.Thread.SpawnConfig = .{},
        ctx: Context.Type = null,
        out: ?Emitter = null,
        state_mu: grt.std.Thread.Mutex = .{},
        running: bool = false,
        async_failed: bool = false,
        has_last_button_id: bool = false,
        last_button_id: ?u32 = null,
        thread: ?grt.std.Thread = null,

        pub fn init(self: *Self, button: drivers.button.Grouped, config: Config) Poller {
            self.* = .{
                .button = button,
                .source_id = config.source_id,
                .ctx = config.ctx,
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
            if (self.running or self.thread != null or self.out == null) {
                self.state_mu.unlock();
                return error.InvalidState;
            }
            self.poll_interval = config.poll_interval;
            self.spawn_config = adaptSpawnConfig(config.spawn_config);
            self.running = true;
            self.async_failed = false;
            self.has_last_button_id = false;
            self.last_button_id = null;
            self.state_mu.unlock();

            const thread = grt.std.Thread.spawn(self.spawn_config, Self.run, .{self}) catch {
                self.state_mu.lock();
                self.running = false;
                self.state_mu.unlock();
                return error.Unexpected;
            };

            self.state_mu.lock();
            self.thread = thread;
            self.state_mu.unlock();
        }

        pub fn stop(self: *Self) void {
            self.state_mu.lock();
            self.running = false;
            const thread = self.thread;
            self.thread = null;
            self.state_mu.unlock();

            if (thread) |t| {
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
                        .ctx = self.ctx,
                    };
                };

                self.pollOnce(snapshot.out, snapshot.source_id, snapshot.ctx) catch {
                    self.failAsync();
                };

                if (snapshot.poll_interval > 0) {
                    grt.std.Thread.sleep(@intCast(snapshot.poll_interval));
                }
            }
        }

        fn pollOnce(self: *Self, out: Emitter, source_id: u32, ctx: Context.Type) !void {
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
                try out.emit(.{
                    .origin = .source,
                    .timestamp = grt.time.instant.now(),
                    .body = .{
                        .raw_grouped_button = .{
                            .source_id = source_id,
                            .button_id = button_id,
                            .pressed = true,
                            .ctx = ctx,
                        },
                    },
                });
                return;
            }

            if (last_button_id) |previous_button_id| {
                try out.emit(.{
                    .origin = .source,
                    .timestamp = grt.time.instant.now(),
                    .body = .{
                        .raw_grouped_button = .{
                            .source_id = source_id,
                            .button_id = previous_button_id,
                            .pressed = false,
                            .ctx = ctx,
                        },
                    },
                });
            }

            if (button_id) |next_button_id| {
                try out.emit(.{
                    .origin = .source,
                    .timestamp = grt.time.instant.now(),
                    .body = .{
                        .raw_grouped_button = .{
                            .source_id = source_id,
                            .button_id = next_button_id,
                            .pressed = true,
                            .ctx = ctx,
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

        fn adaptSpawnConfig(source: @FieldType(Poller.Config, "spawn_config")) grt.std.Thread.SpawnConfig {
            var out: grt.std.Thread.SpawnConfig = .{};
            const Source = @TypeOf(source);

            inline for (@typeInfo(grt.std.Thread.SpawnConfig).@"struct".fields) |field| {
                if (@hasField(Source, field.name)) {
                    @field(out, field.name) = @field(source, field.name);
                }
            }

            return out;
        }
    };
}
