//! testing.IsolationThread — std.Thread-shaped worker namespace for the test runner.
//!
//! This is intentionally scoped to `testing.T` internals. It keeps the runner
//! code depending on a Thread-shaped abstraction instead of platform-specific
//! isolation APIs.

const builtin = @import("builtin");
const native_std = @import("std");
const T = @import("T.zig");
const TestRunnerApi = @import("TestRunner.zig");

pub const ProcessExit = struct {
    raw_status: u32,
    exited: bool = false,
    exit_code: u8 = 0,
    signaled: bool = false,
    signal: u32 = 0,

    fn fromRaw(raw_status: u32) ProcessExit {
        if (comptime switch (builtin.target.os.tag) {
            .linux, .macos => true,
            else => false,
        }) {
            if (native_std.posix.W.IFEXITED(raw_status)) {
                return .{
                    .raw_status = raw_status,
                    .exited = true,
                    .exit_code = native_std.posix.W.EXITSTATUS(raw_status),
                };
            }
            if (native_std.posix.W.IFSIGNALED(raw_status)) {
                return .{
                    .raw_status = raw_status,
                    .signaled = true,
                    .signal = native_std.posix.W.TERMSIG(raw_status),
                };
            }
        }
        return .{ .raw_status = raw_status };
    }
};

fn projectSpawnConfig(comptime std: type, config: anytype) std.Thread.SpawnConfig {
    var projected: std.Thread.SpawnConfig = .{
        .allocator = config.allocator,
    };
    if (@hasField(std.Thread.SpawnConfig, "stack_size") and config.stack_size != 0) {
        projected.stack_size = config.stack_size;
    }
    if (@hasField(std.Thread.SpawnConfig, "priority")) {
        projected.priority = config.priority;
    }
    if (@hasField(std.Thread.SpawnConfig, "name")) {
        projected.name = config.name;
    }
    if (@hasField(std.Thread.SpawnConfig, "core_id")) {
        projected.core_id = config.core_id;
    }
    return projected;
}

fn tupleJoinContext(comptime Args: type, args: Args) ?*anyopaque {
    const info = @typeInfo(Args);
    if (info != .@"struct" or !info.@"struct".is_tuple or info.@"struct".fields.len == 0) return null;

    const First = @TypeOf(args[0]);
    if (@typeInfo(First) != .pointer) return null;

    return @ptrCast(args[0]);
}

fn tupleExitCode(comptime Args: type, args: Args) u8 {
    const info = @typeInfo(Args);
    if (info != .@"struct" or !info.@"struct".is_tuple or info.@"struct".fields.len == 0) return 0;

    const first = args[0];
    const First = @TypeOf(first);
    if (@typeInfo(First) != .pointer) return 0;

    const Target = @typeInfo(First).pointer.child;
    if (@hasField(Target, "ok")) {
        return if (first.ok) 0 else 1;
    }
    return 0;
}

fn processJoinHook(comptime Args: type) ?*const fn (*anyopaque, ProcessExit) void {
    const info = @typeInfo(Args);
    if (info != .@"struct" or !info.@"struct".is_tuple or info.@"struct".fields.len == 0) return null;

    const First = info.@"struct".fields[0].type;
    if (@typeInfo(First) != .pointer) return null;

    const Target = @typeInfo(First).pointer.child;
    if (!@hasField(Target, "ok") and !@hasField(Target, "child")) return null;

    return struct {
        fn call(ptr: *anyopaque, exit: ProcessExit) void {
            const target: First = @ptrCast(@alignCast(ptr));
            if (@hasField(Target, "ok")) {
                target.ok = exit.exited and exit.exit_code == 0;
            }
            if (@hasField(Target, "child")) {
                if (exit.exited) {
                    if (exit.exit_code != 0) {
                        target.child.logFatalf("subtest process exited with code {d}", .{exit.exit_code});
                    }
                } else if (exit.signaled) {
                    target.child.logFatalf("subtest process terminated by signal {d}", .{exit.signal});
                } else {
                    target.child.logFatalf("subtest process ended with status {d}", .{exit.raw_status});
                }
                _ = target.child.wait();
            }
        }
    }.call;
}

pub fn make(comptime std: type, comptime options: anytype) type {
    const process_backend_available = switch (builtin.target.os.tag) {
        .linux, .macos => true,
        else => false,
    };
    const use_process_backend = (@hasField(@TypeOf(options), "isolate") and options.isolate) and process_backend_available;

    const ProcessHandle = if (process_backend_available)
        struct {
            pid: native_std.posix.pid_t,
            context: ?*anyopaque = null,
            on_join: ?*const fn (*anyopaque, ProcessExit) void = null,
        }
    else
        struct {};
    const ProcessSpawnError = if (process_backend_available) native_std.posix.ForkError else error{};

    return struct {
        pub const SpawnConfig = struct {
            stack_size: usize = 0,
            allocator: ?std.mem.Allocator = null,
            priority: u8 = 5,
            name: [*:0]const u8 = "task",
            core_id: ?i32 = null,
        };
        pub const SpawnError = if (@hasDecl(std.Thread, "SpawnError"))
            std.Thread.SpawnError || ProcessSpawnError
        else
            anyerror;
        pub const YieldError = std.Thread.YieldError;
        pub const CpuCountError = std.Thread.CpuCountError;
        pub const SetNameError = std.Thread.SetNameError;
        pub const GetNameError = std.Thread.GetNameError;

        pub const Id = std.Thread.Id;
        pub const max_name_len = std.Thread.max_name_len;
        pub const default_stack_size = std.Thread.default_stack_size;

        pub const Mutex = std.Thread.Mutex;
        pub const Condition = std.Thread.Condition;
        pub const RwLock = std.Thread.RwLock;

        handle: if (use_process_backend) ProcessHandle else std.Thread,

        const Self = @This();

        pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Self {
            if (use_process_backend) {
                const pid = try native_std.posix.fork();
                if (pid == 0) {
                    @call(.auto, f, args);
                    native_std.process.exit(tupleExitCode(@TypeOf(args), args));
                }

                return .{
                    .handle = .{
                        .pid = pid,
                        .context = tupleJoinContext(@TypeOf(args), args),
                        .on_join = processJoinHook(@TypeOf(args)),
                    },
                };
            } else {
                return .{ .handle = try std.Thread.spawn(projectSpawnConfig(std, config), f, args) };
            }
        }

        pub fn join(self: Self) void {
            if (use_process_backend) {
                const wait_result = native_std.posix.waitpid(self.handle.pid, 0);
                if (self.handle.context) |context| {
                    if (self.handle.on_join) |on_join| {
                        on_join(context, ProcessExit.fromRaw(wait_result.status));
                    }
                }
                return;
            }

            self.handle.join();
        }

        pub fn detach(self: Self) void {
            if (use_process_backend) {
                return;
            } else {
                self.handle.detach();
            }
        }

        pub fn yield() YieldError!void {
            return std.Thread.yield();
        }

        pub fn sleep(ns: u64) void {
            std.Thread.sleep(ns);
        }

        pub fn getCpuCount() CpuCountError!usize {
            return std.Thread.getCpuCount();
        }

        pub fn getCurrentId() Id {
            return std.Thread.getCurrentId();
        }

        pub fn setName(name: []const u8) SetNameError!void {
            return std.Thread.setName(name);
        }

        pub fn getName(buffer_ptr: *[max_name_len:0]u8) GetNameError!?[]const u8 {
            return std.Thread.getName(buffer_ptr);
        }
    };
}

pub fn TestRunner(comptime std: type) TestRunnerApi {
    if (builtin.target.os.tag == .freestanding) {
        const Runner = struct {
            pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
                _ = self;
                _ = allocator;
            }

            pub fn run(self: *@This(), t: *T, allocator: std.mem.Allocator) bool {
                _ = self;
                _ = t;
                _ = allocator;
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
        return TestRunnerApi.make(Runner).new(&Holder.runner);
    }

    const TestingThread = make(std, .{ .isolate = false });

    const TestCase = struct {
        fn shapeMatchesThreadSurface() !void {
            _ = TestingThread.SpawnConfig;
            _ = TestingThread.SpawnError;
            _ = TestingThread.Id;
            _ = TestingThread.Mutex;
            _ = TestingThread.Condition;
            _ = TestingThread.RwLock;
            _ = @as(*const fn (TestingThread) void, &TestingThread.join);
            _ = @as(*const fn (TestingThread) void, &TestingThread.detach);
            _ = @as(*const fn (u64) void, &TestingThread.sleep);
            _ = @as(*const fn () TestingThread.CpuCountError!usize, &TestingThread.getCpuCount);
            _ = @as(*const fn () TestingThread.Id, &TestingThread.getCurrentId);
        }

        fn spawnJoinRunsWorker() !void {
            var value = std.atomic.Value(u32).init(0);

            const Worker = struct {
                fn run(state: *std.atomic.Value(u32)) void {
                    state.store(42, .release);
                }
            };

            const worker = try TestingThread.spawn(.{}, Worker.run, .{&value});
            worker.join();

            try std.testing.expectEqual(@as(u32, 42), value.load(.acquire));
        }

        fn synchronizationTypesCoordinate() !void {
            const Sync = struct {
                mutex: TestingThread.Mutex = .{},
                condition: TestingThread.Condition = .{},
                ready: bool = false,
                release: bool = false,
            };

            const Worker = struct {
                fn run(sync: *Sync) void {
                    sync.mutex.lock();
                    sync.ready = true;
                    sync.condition.signal();
                    while (!sync.release) {
                        sync.condition.wait(&sync.mutex);
                    }
                    sync.mutex.unlock();
                }
            };

            var sync: Sync = .{};
            const worker = try TestingThread.spawn(.{}, Worker.run, .{&sync});

            sync.mutex.lock();
            while (!sync.ready) {
                sync.condition.wait(&sync.mutex);
            }
            sync.release = true;
            sync.condition.signal();
            sync.mutex.unlock();

            worker.join();
        }

        fn rwLockAllowsSharedLocking() !void {
            var rwlock: TestingThread.RwLock = .{};

            rwlock.lockShared();
            rwlock.unlockShared();
            rwlock.lock();
            rwlock.unlock();
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("shape_matches_thread_surface", TestRunnerApi.fromFn(std, 64 * 1024, struct {
                fn run(_: *T, _: std.mem.Allocator) !void {
                    try TestCase.shapeMatchesThreadSurface();
                }
            }.run));
            t.run("spawn_join_runs_worker", TestRunnerApi.fromFn(std, 64 * 1024, struct {
                fn run(_: *T, _: std.mem.Allocator) !void {
                    try TestCase.spawnJoinRunsWorker();
                }
            }.run));
            t.run("synchronization_types_coordinate", TestRunnerApi.fromFn(std, 64 * 1024, struct {
                fn run(_: *T, _: std.mem.Allocator) !void {
                    try TestCase.synchronizationTypesCoordinate();
                }
            }.run));
            t.run("rw_lock_allows_shared_locking", TestRunnerApi.fromFn(std, 64 * 1024, struct {
                fn run(_: *T, _: std.mem.Allocator) !void {
                    try TestCase.rwLockAllowsSharedLocking();
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return TestRunnerApi.make(Runner).new(&Holder.runner);
}
