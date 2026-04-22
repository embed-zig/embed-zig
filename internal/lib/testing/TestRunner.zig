//! testing.TestRunner — thin vtable wrapper around a typed runner object.
//!
//! `make(TestRunner).new(ctx)` borrows `ctx`, calls `ctx.init(allocator)` from
//! `run()`, then forwards to `ctx.run(t, allocator)`.
//!
//! Factory: `fromFn` — `run_fn(t, allocator)` on a worker thread; `stack_size` sets
//! `spawn_config.stack_size` for that worker (callers choose an explicit size per case).

const builtin = @import("builtin");
const embed = @import("embed");
const Self = @This();
const T = @import("T.zig");

var default_ctx_byte: u8 = 0;

ctx: *anyopaque,
vtable: *const VTable,
spawn_config: embed.Thread.SpawnConfig = .{},
memory_limit: ?usize = null,

pub const VTable = struct {
    runFn: *const fn (*Self, *T, embed.mem.Allocator) bool,
    deinitFn: *const fn (Self, embed.mem.Allocator) void = noopDeinit,
};

const Options = struct {
    ctx: *anyopaque = defaultCtx(),
    vtable: *const VTable,
    spawn_config: embed.Thread.SpawnConfig = .{},
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

pub fn run(self: *Self, t: *T, allocator: embed.mem.Allocator) bool {
    return self.vtable.runFn(self, t, allocator);
}

pub fn deinit(self: Self, allocator: embed.mem.Allocator) void {
    self.vtable.deinitFn(self, allocator);
}

pub fn make(comptime RunnerType: type) type {
    comptime {
        _ = @as(*const fn (*RunnerType, embed.mem.Allocator) anyerror!void, RunnerType.init);
        _ = @as(*const fn (*RunnerType, *T, embed.mem.Allocator) bool, RunnerType.run);
        _ = @as(*const fn (*RunnerType, embed.mem.Allocator) void, RunnerType.deinit);
    }
    return struct {
        pub fn new(ctx: *RunnerType) Self {
            const Impl = struct {
                const vtable: VTable = .{
                    .runFn = @This().run,
                    .deinitFn = @This().deinit,
                };

                fn run(runner: *Self, t: *T, allocator: embed.mem.Allocator) bool {
                    const typed_ctx: *RunnerType = @ptrCast(@alignCast(runner.ctx));
                    RunnerType.init(typed_ctx, allocator) catch |err| {
                        t.logErrorf("runner init failed: {}", .{err});
                        return false;
                    };
                    return RunnerType.run(typed_ctx, t, allocator);
                }

                fn deinit(runner: Self, allocator: embed.mem.Allocator) void {
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
    comptime lib: type,
    comptime stack_size: usize,
    comptime run_fn: *const fn (t: *T, allocator: lib.mem.Allocator) anyerror!void,
) Self {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = stack_size },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *T, allocator: embed.mem.Allocator) bool {
            _ = self;

            run_fn(t, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
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

fn noopDeinit(_: Self, _: embed.mem.Allocator) void {}

pub fn TestRunner(comptime lib: type) Self {
    if (builtin.target.os.tag == .freestanding) {
        const Runner = struct {
            pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
                _ = self;
                _ = allocator;
            }

            pub fn run(self: *@This(), t: *T, allocator: embed.mem.Allocator) bool {
                _ = self;
                _ = t;
                _ = allocator;
                return true;
            }

            pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
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
            const std = @import("std");

            const RunnerState = struct {
                run_hits: usize = 0,
                deinit_hits: usize = 0,
                expected_allocator_ptr: usize = 0,
            };

            const Helper = struct {
                fn run(runner: *Self, t: *T, allocator: embed.mem.Allocator) bool {
                    const state: *RunnerState = @ptrCast(@alignCast(runner.ctx));
                    _ = t;
                    state.run_hits += 1;
                    state.expected_allocator_ptr = @intFromPtr(allocator.ptr);
                    return true;
                }

                fn deinit(runner: Self, allocator: embed.mem.Allocator) void {
                    const state: *RunnerState = @ptrCast(@alignCast(runner.ctx));
                    _ = allocator;
                    state.deinit_hits += 1;
                }
            };

            var state = RunnerState{};
            var handle = T.new(std, .test_run);
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
            const std = @import("std");

            const OwnedArgs = struct {
                seed: usize,
                init_allocator_ptr: usize,
                deinit_hits: usize = 0,
                spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 4096 },
                memory_limit: ?usize = 21,

                pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
                    self.init_allocator_ptr = @intFromPtr(allocator.ptr);
                }

                pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
                    _ = allocator;
                    self.deinit_hits += 1;
                }

                pub fn run(self: *@This(), test_handle: *T, allocator: embed.mem.Allocator) bool {
                    _ = test_handle;
                    return self.seed == 5 and self.init_allocator_ptr == @intFromPtr(allocator.ptr);
                }
            };

            var t = T.new(std, .test_run);
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
            const std = @import("std");

            const OwnedArgs = struct {
                deinit_hits: usize = 0,

                pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
                    _ = self;
                    _ = allocator;
                }

                pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
                    _ = allocator;
                    self.deinit_hits += 1;
                }

                pub fn run(self: *@This(), test_handle: *T, allocator: embed.mem.Allocator) bool {
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
            const std = @import("std");

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
                pub fn scoped(comptime scope: @Type(.enum_literal)) type {
                    _ = scope;
                    return struct {
                        pub fn info(comptime format: []const u8, args: anytype) void {
                            Support.append(format, args);
                        }

                        pub fn err(comptime format: []const u8, args: anytype) void {
                            Support.append(format, args);
                        }
                    };
                }
            };

            const TestLib = struct {
                pub const mem = embed.mem;
                pub const fmt = embed.fmt;
                pub const Thread = std.Thread;
                pub const log = CapturingLog;
                pub fn ArrayList(comptime Elem: type) type {
                    return std.ArrayList(Elem);
                }
                pub const testing = struct {
                    pub const allocator = std.testing.allocator;
                };
                pub const time = struct {
                    pub const ns_per_ms = std.time.ns_per_ms;

                    pub fn nanoTimestamp() i128 {
                        return std.time.nanoTimestamp();
                    }

                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const OwnedArgs = struct {
                run_hits: usize = 0,
                deinit_hits: usize = 0,

                pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
                    _ = self;
                    _ = allocator;
                    return error.InitFailed;
                }

                pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
                    _ = allocator;
                    self.deinit_hits += 1;
                }

                pub fn run(self: *@This(), test_handle: *T, allocator: embed.mem.Allocator) bool {
                    _ = test_handle;
                    _ = allocator;
                    self.run_hits += 1;
                    return true;
                }
            };

            Support.reset();
            defer Support.reset();

            var t = T.new(TestLib, .test_run);
            defer t.deinit();

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
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *T, allocator: lib.mem.Allocator) bool {
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
                fn run(_: *T, case_allocator: lib.mem.Allocator) !void {
                    _ = case_allocator;
                }
            };
            var from_fn_runner = Self.fromFn(lib, 256 * 1024, FromFnCases.run);
            if (!from_fn_runner.run(t, allocator)) return false;
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return Self.make(Runner).new(&Holder.runner);
}
