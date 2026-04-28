const context_mod = @import("context");
const testing_api = @import("testing");
const time_mod = @import("time");

pub fn Racer(comptime std: type, comptime time: type, comptime T: type) type {
    const Allocator = std.mem.Allocator;
    const Thread = std.Thread;
    const Atomic = std.atomic.Value;

    return struct {
        allocator: Allocator,
        shared: *SharedState,

        const Self = @This();

        const SharedState = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            done: Atomic(bool) = Atomic(bool).init(false),
            running: usize = 0,
            has_value: bool = false,
            value: T = undefined,
        };

        pub const Result = union(enum) {
            winner: T,
            exhausted,
        };

        pub const State = struct {
            shared: *SharedState,

            /// True once a terminal outcome has been published or cancellation requested.
            pub fn done(self: State) bool {
                return self.shared.done.load(.acquire);
            }

            /// Returns the current winning value, if any.
            pub fn value(self: State) ?T {
                self.shared.mutex.lock();
                defer self.shared.mutex.unlock();

                if (!self.shared.has_value) return null;
                return self.shared.value;
            }

            /// Publishes a successful result. Only the first success wins.
            pub fn success(self: State, result: T) bool {
                self.shared.mutex.lock();
                defer self.shared.mutex.unlock();

                if (self.shared.has_value or self.shared.done.load(.acquire)) return false;

                self.shared.value = result;
                self.shared.has_value = true;
                self.shared.done.store(true, .release);
                self.shared.cond.broadcast();
                return true;
            }
        };

        pub fn init(allocator: Allocator) Allocator.Error!Self {
            const shared = try allocator.create(SharedState);
            shared.* = .{};
            return .{
                .allocator = allocator,
                .shared = shared,
            };
        }

        /// Waits for all detached tasks to exit, then frees the shared state.
        pub fn deinit(self: *Self) void {
            self.wait();
            self.allocator.destroy(self.shared);
            self.* = undefined;
        }

        /// True once a terminal outcome has been published or cancellation requested.
        pub fn done(self: *Self) bool {
            return self.shared.done.load(.acquire);
        }

        /// Signals spawned tasks to stop cooperatively. This does not force
        /// `race()` to return early; callers should pair it with their own
        /// cancellation path and then `wait()` / `deinit()` as needed.
        pub fn cancel(self: *Self) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            if (self.shared.done.load(.acquire)) return;
            self.shared.done.store(true, .release);
            self.shared.cond.broadcast();
        }

        /// Returns the current winning value, if any.
        pub fn value(self: *Self) ?T {
            const state: State = .{ .shared = self.shared };
            return state.value();
        }

        /// Spawns a detached task. The task receives a `State` as its first
        /// argument, followed by `args`.
        ///
        /// Task return type must be `void` or `!void`. The task is responsible
        /// for exiting on its own; Racer only records winner publication and
        /// task completion.
        pub fn spawn(self: *Self, config: Thread.SpawnConfig, comptime f: anytype, args: anytype) Thread.SpawnError!void {
            var spawn_config = config;
            if (@hasField(Thread.SpawnConfig, "allocator")) {
                if (spawn_config.allocator == null) {
                    spawn_config.allocator = self.allocator;
                }
            }

            startTask(self.shared);
            errdefer finishTask(self.shared);

            const Wrapper = struct {
                fn run(shared: *SharedState, user_args: @TypeOf(args)) void {
                    defer finishTask(shared);
                    const state: State = .{ .shared = shared };
                    callTask(state, user_args);
                }

                fn callTask(state: State, user_args: @TypeOf(args)) void {
                    const Fn = @TypeOf(f);
                    const fn_info = @typeInfo(Fn).@"fn";
                    const Return = fn_info.return_type orelse @compileError("racer task must have an explicit return type");

                    switch (@typeInfo(Return)) {
                        .void => @call(.auto, f, .{state} ++ user_args),
                        .error_union => |eu| {
                            if (eu.payload != void)
                                @compileError("racer task must return void or !void");
                            _ = @call(.auto, f, .{state} ++ user_args) catch {};
                        },
                        else => @compileError("racer task must return void or !void"),
                    }
                }
            };

            var t = try Thread.spawn(spawn_config, Wrapper.run, .{ self.shared, args });
            t.detach();
        }

        /// Waits until either a winner is published or all tasks finish.
        /// Multiple calls return the same winning value, or `.exhausted` if no
        /// task ever published one.
        pub fn race(self: *Self) Result {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            while (!self.shared.has_value and self.shared.running != 0) {
                self.shared.cond.wait(&self.shared.mutex);
            }

            if (self.shared.has_value) return .{ .winner = self.shared.value };
            return .exhausted;
        }

        /// Waits until either a winner is published, all tasks finish, or the
        /// provided context is canceled/deadlines out.
        ///
        /// Note: the external context is checked before returning an already
        /// published winner, so a pre-canceled context still causes
        /// `raceContext()` to return that context error.
        pub fn raceContext(self: *Self, ctx: context_mod.Context) anyerror!Result {
            if (ctx.err()) |err| return err;

            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            while (!self.shared.has_value and self.shared.running != 0) {
                if (ctx.err()) |err| return err;

                const timed_wait: time_mod.duration.Duration = blk: {
                    const poll_interval: time_mod.duration.Duration = 10 * time_mod.duration.MilliSecond;
                    if (ctx.deadline()) |deadline| {
                        const remaining = time_mod.instant.sub(deadline, time.instant.now());
                        if (remaining <= 0) break :blk 0;
                        break :blk @min(remaining, poll_interval);
                    }
                    break :blk poll_interval;
                };

                if (timed_wait == 0) {
                    if (ctx.err()) |err| return err;
                    return error.DeadlineExceeded;
                }

                self.shared.cond.timedWait(&self.shared.mutex, @intCast(timed_wait)) catch {};
            }

            if (self.shared.has_value) return .{ .winner = self.shared.value };
            if (ctx.err()) |err| return err;
            return .exhausted;
        }

        /// Waits until all detached tasks have exited.
        /// Safe to call multiple times.
        pub fn wait(self: *Self) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            while (self.shared.running != 0) {
                self.shared.cond.wait(&self.shared.mutex);
            }
        }

        fn startTask(shared: *SharedState) void {
            shared.mutex.lock();
            defer shared.mutex.unlock();
            shared.running += 1;
        }

        fn finishTask(shared: *SharedState) void {
            shared.mutex.lock();
            defer shared.mutex.unlock();

            std.debug.assert(shared.running > 0);
            shared.running -= 1;
            if (shared.running == 0) shared.cond.broadcast();
        }
    };
}

pub fn TestRunner(comptime std: type, comptime time: type) testing_api.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const R = Racer(std, time, u32);

            var racer = try R.init(std.testing.allocator);
            defer racer.deinit();

            switch (racer.race()) {
                .winner => return error.UnexpectedWinner,
                .exhausted => {},
            }

            try std.testing.expect(!racer.done());
            try std.testing.expectEqual(@as(?u32, null), racer.value());

            racer.cancel();
            try std.testing.expect(racer.done());

            switch (racer.race()) {
                .winner => return error.UnexpectedWinner,
                .exhausted => {},
            }

            racer.wait();
            racer.wait();
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
