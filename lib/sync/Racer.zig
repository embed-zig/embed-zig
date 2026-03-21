const std = @import("std");
const context_mod = @import("context");

pub fn Racer(comptime lib: type, comptime T: type) type {
    const Allocator = lib.mem.Allocator;
    const Thread = lib.Thread;
    const Atomic = lib.atomic.Value;

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

            /// True once a winning value has been published.
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

                if (self.shared.has_value) return false;

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

        /// True once a winning value has been published.
        pub fn done(self: *Self) bool {
            return self.shared.done.load(.acquire);
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

                const wait_ns: u64 = blk: {
                    const poll_ms: i64 = 10;
                    if (ctx.deadline()) |deadline_ms| {
                        const remaining_ms = deadline_ms - lib.time.milliTimestamp();
                        if (remaining_ms <= 0) break :blk 0;
                        break :blk @as(u64, @intCast(@min(remaining_ms, poll_ms))) * std.time.ns_per_ms;
                    }
                    break :blk @as(u64, @intCast(poll_ms)) * std.time.ns_per_ms;
                };

                if (wait_ns == 0) {
                    if (ctx.err()) |err| return err;
                    return error.DeadlineExceeded;
                }

                self.shared.cond.timedWait(&self.shared.mutex, wait_ns) catch {};
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
