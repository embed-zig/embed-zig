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

        button: drivers.button.Single,
        source_id: u32,
        poll_interval_ns: u64 = Poller.default_poll_interval_ns,
        spawn_config: grt.std.Thread.SpawnConfig = .{},
        ctx: Context.Type = null,
        out: ?Emitter = null,
        state_mu: grt.std.Thread.Mutex = .{},
        running: bool = false,
        async_failed: bool = false,
        last_pressed: ?bool = null,
        thread: ?grt.std.Thread = null,

        pub fn init(self: *Self, button: drivers.button.Single, config: Config) Poller {
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
            self.poll_interval_ns = config.poll_interval_ns;
            self.spawn_config = adaptSpawnConfig(config.spawn_config);
            self.running = true;
            self.async_failed = false;
            self.last_pressed = null;
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
                        .poll_interval_ns = self.poll_interval_ns,
                        .ctx = self.ctx,
                    };
                };

                self.pollOnce(snapshot.out, snapshot.source_id, snapshot.ctx) catch {
                    self.failAsync();
                };

                if (snapshot.poll_interval_ns > 0) {
                    grt.std.Thread.sleep(snapshot.poll_interval_ns);
                }
            }
        }

        fn pollOnce(self: *Self, out: Emitter, source_id: u32, ctx: Context.Type) !void {
            const pressed = try self.button.isPressed();
            self.state_mu.lock();
            const last_pressed = self.last_pressed;
            if (last_pressed != null and last_pressed.? == pressed) {
                self.state_mu.unlock();
                return;
            }
            self.last_pressed = pressed;
            self.state_mu.unlock();

            try out.emit(.{
                .origin = .source,
                .timestamp_ns = grt.std.time.nanoTimestamp(),
                .body = .{
                    .raw_single_button = .{
                        .source_id = source_id,
                        .pressed = pressed,
                        .ctx = ctx,
                    },
                },
            });
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
