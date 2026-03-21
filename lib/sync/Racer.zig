const std = @import("std");

pub fn Racer(comptime lib: type, comptime T: type) type {
    const Allocator = lib.mem.Allocator;
    const Thread = lib.Thread;
    const Atomic = lib.atomic.Value;

    return struct {
        allocator: Allocator,
        state: *State,

        const Self = @This();

        const State = struct {
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

        pub const Context = struct {
            state: *State,

            /// True once a winning value has been published.
            pub fn done(self: Context) bool {
                return self.state.done.load(.acquire);
            }

            /// Returns the current winning value, if any.
            pub fn value(self: Context) ?T {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();

                if (!self.state.has_value) return null;
                return self.state.value;
            }

            /// Publishes a successful result. Only the first success wins.
            pub fn success(self: Context, result: T) bool {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();

                if (self.state.has_value) return false;

                self.state.value = result;
                self.state.has_value = true;
                self.state.done.store(true, .release);
                self.state.cond.broadcast();
                return true;
            }
        };

        pub fn init(allocator: Allocator) Allocator.Error!Self {
            const state = try allocator.create(State);
            state.* = .{};
            return .{
                .allocator = allocator,
                .state = state,
            };
        }

        /// Waits for all detached tasks to exit, then frees the shared state.
        pub fn deinit(self: *Self) void {
            self.wait();
            self.allocator.destroy(self.state);
            self.* = undefined;
        }

        /// True once a winning value has been published.
        pub fn done(self: *Self) bool {
            return self.state.done.load(.acquire);
        }

        /// Returns the current winning value, if any.
        pub fn value(self: *Self) ?T {
            const ctx = Context{ .state = self.state };
            return ctx.value();
        }

        /// Spawns a detached task. The task receives a `Context` as its first
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

            startTask(self.state);
            errdefer finishTask(self.state);

            const Wrapper = struct {
                fn run(state: *State, user_args: @TypeOf(args)) void {
                    defer finishTask(state);
                    const ctx: Context = .{ .state = state };
                    callTask(ctx, user_args);
                }

                fn callTask(ctx: Context, user_args: @TypeOf(args)) void {
                    const Fn = @TypeOf(f);
                    const fn_info = @typeInfo(Fn).@"fn";
                    const Return = fn_info.return_type orelse @compileError("racer task must have an explicit return type");

                    switch (@typeInfo(Return)) {
                        .void => @call(.auto, f, .{ctx} ++ user_args),
                        .error_union => |eu| {
                            if (eu.payload != void)
                                @compileError("racer task must return void or !void");
                            _ = @call(.auto, f, .{ctx} ++ user_args) catch {};
                        },
                        else => @compileError("racer task must return void or !void"),
                    }
                }
            };

            var t = try Thread.spawn(spawn_config, Wrapper.run, .{ self.state, args });
            t.detach();
        }

        /// Waits until either a winner is published or all tasks finish.
        /// Multiple calls return the same winning value, or `.exhausted` if no
        /// task ever published one.
        pub fn race(self: *Self) Result {
            self.state.mutex.lock();
            defer self.state.mutex.unlock();

            while (!self.state.has_value and self.state.running != 0) {
                self.state.cond.wait(&self.state.mutex);
            }

            if (self.state.has_value) return .{ .winner = self.state.value };
            return .exhausted;
        }

        /// Waits until all detached tasks have exited.
        /// Safe to call multiple times.
        pub fn wait(self: *Self) void {
            self.state.mutex.lock();
            defer self.state.mutex.unlock();

            while (self.state.running != 0) {
                self.state.cond.wait(&self.state.mutex);
            }
        }

        fn startTask(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.running += 1;
        }

        fn finishTask(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();

            std.debug.assert(state.running > 0);
            state.running -= 1;
            if (state.running == 0) state.cond.broadcast();
        }
    };
}