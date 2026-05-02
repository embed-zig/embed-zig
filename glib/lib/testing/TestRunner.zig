//! testing.TestRunner — thin vtable wrapper around a typed runner object.
//!
//! `make(TestRunner).new(ctx)` borrows `ctx`, calls `ctx.init(allocator)` from
//! `run()`, then forwards to `ctx.run(t, allocator)`.
//!
//! Factory: `fromFn` — `run_fn(t, allocator)` on a worker thread; `stack_size` sets
//! `spawn_config.stack_size` for that worker (callers choose an explicit size per case).

const builtin = @import("builtin");
const stdz = @import("stdz");
const time_mod = @import("time");
const Self = @This();
const T = @import("T.zig");

var default_ctx_byte: u8 = 0;

ctx: *anyopaque,
vtable: *const VTable,
spawn_config: stdz.Thread.SpawnConfig = .{},
memory_limit: ?usize = null,

pub const VTable = struct {
    runFn: *const fn (*Self, *T, stdz.mem.Allocator) bool,
    deinitFn: *const fn (Self, stdz.mem.Allocator) void = noopDeinit,
};

const Options = struct {
    ctx: *anyopaque = defaultCtx(),
    vtable: *const VTable,
    spawn_config: stdz.Thread.SpawnConfig = .{},
    memory_limit: ?usize = null,
};

fn init(options: Options) Self {
    return .{
        .ctx = options.ctx,
        .vtable = options.vtable,
        .spawn_config = options.spawn_config,
        .memory_limit = options.memory_limit,
    };
}

pub fn run(self: *Self, t: *T, allocator: stdz.mem.Allocator) bool {
    return self.vtable.runFn(self, t, allocator);
}

pub fn deinit(self: Self, allocator: stdz.mem.Allocator) void {
    self.vtable.deinitFn(self, allocator);
}

pub fn make(comptime RunnerType: type) type {
    comptime {
        _ = @as(*const fn (*RunnerType, stdz.mem.Allocator) anyerror!void, RunnerType.init);
        _ = @as(*const fn (*RunnerType, *T, stdz.mem.Allocator) bool, RunnerType.run);
        _ = @as(*const fn (*RunnerType, stdz.mem.Allocator) void, RunnerType.deinit);
    }
    return struct {
        pub fn new(ctx: *RunnerType) Self {
            const Impl = struct {
                const vtable: VTable = .{
                    .runFn = @This().run,
                    .deinitFn = @This().deinit,
                };

                fn run(runner: *Self, t: *T, allocator: stdz.mem.Allocator) bool {
                    const typed_ctx: *RunnerType = @ptrCast(@alignCast(runner.ctx));
                    RunnerType.init(typed_ctx, allocator) catch |err| {
                        t.logErrorf("runner init failed: {}", .{err});
                        return false;
                    };
                    return RunnerType.run(typed_ctx, t, allocator);
                }

                fn deinit(runner: Self, allocator: stdz.mem.Allocator) void {
                    const typed_ctx: *RunnerType = @ptrCast(@alignCast(runner.ctx));
                    RunnerType.deinit(typed_ctx, allocator);
                }
            };

            return init(.{
                .ctx = @ptrCast(ctx),
                .vtable = &Impl.vtable,
                .spawn_config = if (@hasField(RunnerType, "spawn_config")) ctx.spawn_config else .{},
                .memory_limit = if (@hasField(RunnerType, "memory_limit")) ctx.memory_limit else null,
            });
        }
    };
}

pub fn fromFn(
    comptime std: type,
    comptime stack_size: usize,
    comptime run_fn: *const fn (t: *T, allocator: std.mem.Allocator) anyerror!void,
) Self {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = stack_size },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *T, allocator: stdz.mem.Allocator) bool {
            _ = self;

            run_fn(t, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return Self.make(Runner).new(&Holder.runner);
}

fn defaultCtx() *anyopaque {
    return @ptrCast(&default_ctx_byte);
}

fn noopDeinit(_: Self, _: stdz.mem.Allocator) void {}

pub fn TestRunner(comptime std: type, comptime time: type) Self {
    if (builtin.target.os.tag == .freestanding) {
        const Runner = struct {
            pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
                _ = self;
                _ = allocator;
            }

            pub fn run(self: *@This(), t: *T, allocator: stdz.mem.Allocator) bool {
                _ = self;
                _ = t;
                _ = allocator;
                return true;
            }

            pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                _ = self;
                _ = allocator;
            }
        };

        const Holder = struct {
            var runner: Runner = .{};
        };
        return Self.make(Runner).new(&Holder.runner);
    }

    const TestCase = struct {
        fn testForwardsRunAndDeinit() !void {
            const RunnerState = struct {
                run_hits: usize = 0,
                deinit_hits: usize = 0,
                expected_allocator_ptr: usize = 0,
            };

            const Helper = struct {
                fn run(runner: *Self, t: *T, allocator: stdz.mem.Allocator) bool {
                    const state: *RunnerState = @ptrCast(@alignCast(runner.ctx));
                    _ = t;
                    state.run_hits += 1;
                    state.expected_allocator_ptr = @intFromPtr(allocator.ptr);
                    return true;
                }

                fn deinit(runner: Self, allocator: stdz.mem.Allocator) void {
                    const state: *RunnerState = @ptrCast(@alignCast(runner.ctx));
                    _ = allocator;
                    state.deinit_hits += 1;
                }
            };

            var state = RunnerState{};
            var handle = T.new(std, time, .test_run);
            defer {
                std.testing.expect(handle.wait()) catch @panic("handle wait failed");
                handle.deinit();
            }
            var runner = Self.init(.{
                .ctx = @ptrCast(&state),
                .vtable = &.{
                    .runFn = Helper.run,
                    .deinitFn = Helper.deinit,
                },
                .spawn_config = .{ .stack_size = 1234 },
                .memory_limit = 99,
            });

            try std.testing.expectEqual(@as(usize, 1234), runner.spawn_config.stack_size);
            try std.testing.expectEqual(@as(?usize, 99), runner.memory_limit);
            try std.testing.expect(runner.run(&handle, std.testing.allocator));
            try std.testing.expectEqual(@as(usize, 1), state.run_hits);
            try std.testing.expectEqual(@intFromPtr(std.testing.allocator.ptr), state.expected_allocator_ptr);

            runner.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), state.deinit_hits);
        }

        fn testNewOwnsState() !void {
            const OwnedArgs = struct {
                seed: usize,
                init_allocator_ptr: usize,
                deinit_hits: usize = 0,
                spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 4096 },
                memory_limit: ?usize = 21,

                pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                    self.init_allocator_ptr = @intFromPtr(allocator.ptr);
                }

                pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                    _ = allocator;
                    self.deinit_hits += 1;
                }

                pub fn run(self: *@This(), test_handle: *T, allocator: stdz.mem.Allocator) bool {
                    _ = test_handle;
                    return self.seed == 5 and self.init_allocator_ptr == @intFromPtr(allocator.ptr);
                }
            };

            var t = T.new(std, time, .test_run);
            defer {
                std.testing.expect(t.wait()) catch @panic("t wait failed");
                t.deinit();
            }
            var ctx = OwnedArgs{
                .seed = 5,
                .init_allocator_ptr = 0,
            };
            const RunnerType = Self.make(OwnedArgs);
            var runner = RunnerType.new(&ctx);

            try std.testing.expectEqual(@as(usize, 4096), runner.spawn_config.stack_size);
            try std.testing.expectEqual(@as(?usize, 21), runner.memory_limit);
            try std.testing.expect(runner.run(&t, std.testing.allocator));
            try std.testing.expectEqual(@as(usize, 0), ctx.deinit_hits);
            runner.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), ctx.deinit_hits);
        }

        fn testNewDeinitWithoutRunIsOk() !void {
            const OwnedArgs = struct {
                deinit_hits: usize = 0,

                pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                    _ = self;
                    _ = allocator;
                }

                pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                    _ = allocator;
                    self.deinit_hits += 1;
                }

                pub fn run(self: *@This(), test_handle: *T, allocator: stdz.mem.Allocator) bool {
                    _ = self;
                    _ = test_handle;
                    _ = allocator;
                    return true;
                }
            };

            var ctx = OwnedArgs{};
            const RunnerType = Self.make(OwnedArgs);
            var runner = RunnerType.new(&ctx);

            runner.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), ctx.deinit_hits);
        }

        fn testInitFailureMarksTestFailed() !void {
            const Support = struct {
                var entries: std.ArrayListUnmanaged([]u8) = .{};
                var mutex: std.Thread.Mutex = .{};

                fn reset() void {
                    mutex.lock();
                    defer mutex.unlock();
                    for (entries.items) |entry| {
                        std.testing.allocator.free(entry);
                    }
                    entries.deinit(std.testing.allocator);
                    entries = .{};
                }

                fn append(comptime format: []const u8, args: anytype) void {
                    const message = std.fmt.allocPrint(std.testing.allocator, format, args) catch @panic("OOM");
                    mutex.lock();
                    defer mutex.unlock();
                    entries.append(std.testing.allocator, message) catch @panic("OOM");
                }

                fn joinedLog(allocator: std.mem.Allocator) ![]u8 {
                    mutex.lock();
                    defer mutex.unlock();

                    var bytes = try std.ArrayList(u8).initCapacity(allocator, 0);
                    errdefer bytes.deinit(allocator);

                    for (entries.items, 0..) |entry, idx| {
                        try bytes.appendSlice(allocator, entry);
                        if (idx + 1 != entries.items.len) {
                            try bytes.append(allocator, '\n');
                        }
                    }
                    return bytes.toOwnedSlice(allocator);
                }
            };

            const CapturingLog = struct {
                fn err(comptime format: []const u8, args: anytype) void {
                    Support.append(format, args);
                }
            };

            const OwnedArgs = struct {
                run_hits: usize = 0,
                deinit_hits: usize = 0,

                pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                    _ = self;
                    _ = allocator;
                    return error.InitFailed;
                }

                pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                    _ = allocator;
                    self.deinit_hits += 1;
                }

                pub fn run(self: *@This(), test_handle: *T, allocator: stdz.mem.Allocator) bool {
                    _ = test_handle;
                    _ = allocator;
                    self.run_hits += 1;
                    return true;
                }
            };

            const TestState = struct {
                failed: bool = false,
            };
            const TestVTable = struct {
                fn noopCreated(_: *T) void {}
                fn noopDestroyed(_: *T) void {}
                fn noopTDeinit(_: *T) void {}
                fn noopDestroyDebug(_: *T, _: []const u8) void {}
                fn noopInfo(_: *anyopaque, _: []const u8) void {}
                fn recordError(ptr: *anyopaque, message: []const u8) void {
                    const state: *TestState = @ptrCast(@alignCast(ptr));
                    state.failed = true;
                    CapturingLog.err("{s}", .{message});
                }
                fn noopFatal(_: *T, _: []const u8) void {}
                fn noopTimeout(_: *T, _: time_mod.duration.Duration) void {}
                fn noopRun(_: *T, _: []const u8, _: Self) void {}
                fn wait(t: *T) bool {
                    const state: *TestState = @ptrCast(@alignCast(t.ptr));
                    return !state.failed;
                }

                const vtable: T.VTable = .{
                    .onCreatedFn = noopCreated,
                    .onDestroyedFn = noopDestroyed,
                    .deinitFn = noopTDeinit,
                    .enableDestroyDebugFn = noopDestroyDebug,
                    .logInfoFn = noopInfo,
                    .logErrorFn = recordError,
                    .logFatalFn = noopFatal,
                    .timeoutFn = noopTimeout,
                    .runFn = noopRun,
                    .waitFn = wait,
                };
            };

            Support.reset();
            defer Support.reset();

            var test_state = TestState{};
            var t: T = .{
                .ptr = @ptrCast(&test_state),
                .vtable = &TestVTable.vtable,
                .allocator = std.testing.allocator,
                .ctx = undefined,
                .test_name = "init_failure",
                .relative_started = 0,
            };

            var ctx = OwnedArgs{};
            const RunnerType = Self.make(OwnedArgs);
            var runner = RunnerType.new(&ctx);

            try std.testing.expect(!runner.run(&t, std.testing.allocator));
            try std.testing.expectEqual(@as(usize, 0), ctx.run_hits);
            try std.testing.expect(!t.wait());

            runner.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), ctx.deinit_hits);

            const log = try Support.joinedLog(std.testing.allocator);
            defer std.testing.allocator.free(log);
            try std.testing.expect(std.mem.indexOf(u8, log, "runner init failed: error.InitFailed") != null);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *T, allocator: std.mem.Allocator) bool {
            _ = self;

            TestCase.testForwardsRunAndDeinit() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testNewOwnsState() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testNewDeinitWithoutRunIsOk() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testInitFailureMarksTestFailed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            const FromFnCases = struct {
                fn run(_: *T, case_allocator: std.mem.Allocator) !void {
                    _ = case_allocator;
                }
            };
            var from_fn_runner = Self.fromFn(std, 256 * 1024, FromFnCases.run);
            if (!from_fn_runner.run(t, allocator)) return false;
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
    return Self.make(Runner).new(&Holder.runner);
}
