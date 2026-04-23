//! testing.T — type-erased test handle with vtable-backed behavior.

const builtin = @import("builtin");
const stdz_mod = @import("stdz");
const context_mod = @import("context");
const Context = context_mod.Context;
const TestRunnerHandle = @import("TestRunner.zig");
const Self = @This();

const open_marker = ">>>";
const done_marker = "<<<";
const fail_marker = "!!!";
const open_color = "\x1b[34m";
const done_color = "\x1b[32m";
const fail_color = "\x1b[31m";
const color_reset = "\x1b[0m";
const structured_label_width = 32;
const summary_label = "summary";
const padding_spaces =
    "                                                                ";

ptr: *anyopaque,
vtable: *const VTable,
allocator: stdz_mod.mem.Allocator,
ctx: Context,
test_name: []const u8,
relative_started_ns: u64,
is_parallel: bool = false,
test_hook: TestHook = .{},

pub const BeforeRunHook = *const fn (*Self, *TestRunnerHandle) void;
pub const TestHook = struct {
    beforeRun: ?BeforeRunHook = null,
};

pub const VTable = struct {
    onCreatedFn: *const fn (*Self) void,
    onDestroyedFn: *const fn (*Self) void,
    deinitFn: *const fn (*Self) void,
    enableDestroyDebugFn: *const fn (*Self, []const u8) void,
    logInfoFn: *const fn (*anyopaque, []const u8) void,
    logErrorFn: *const fn (*anyopaque, []const u8) void,
    logFatalFn: *const fn (*Self, []const u8) void,
    timeoutFn: *const fn (*Self, i64) void,
    runFn: *const fn (*Self, []const u8, TestRunnerHandle) void,
    waitFn: *const fn (*Self) bool,
};

const InitOptions = struct {
    ptr: *anyopaque,
    allocator: stdz_mod.mem.Allocator,
    context: Context,
    relative_started_ns: u64 = 0,
    vtable: *const VTable,
    test_hook: TestHook = .{},
};

fn init(test_name: []const u8, options: InitOptions) Self {
    var self: Self = .{
        .ptr = options.ptr,
        .vtable = options.vtable,
        .allocator = options.allocator,
        .ctx = options.context,
        .test_name = test_name,
        .relative_started_ns = options.relative_started_ns,
        .is_parallel = false,
        .test_hook = options.test_hook,
    };
    self.vtable.onCreatedFn(&self);
    return self;
}

pub fn deinit(self: *Self) void {
    self.vtable.onDestroyedFn(self);
    self.vtable.deinitFn(self);
    self.* = undefined;
}

pub fn enableDestroyDebug(self: *Self, tag: []const u8) void {
    self.vtable.enableDestroyDebugFn(self, tag);
}

pub fn context(self: Self) Context {
    return self.ctx;
}

pub fn logFatal(self: *Self, message: []const u8) void {
    self.vtable.logFatalFn(self, message);
}

pub fn logFatalf(self: *Self, comptime format: []const u8, args: anytype) void {
    const message = stdz_mod.fmt.allocPrint(self.allocator, format, args) catch {
        self.logFatal("logFatalf format failed");
        return;
    };
    defer self.allocator.free(message);
    self.logFatal(message);
}

pub fn name(self: Self) []const u8 {
    return self.test_name;
}

pub fn logInfo(self: Self, message: []const u8) void {
    self.vtable.logInfoFn(self.ptr, message);
}

pub fn logInfof(self: Self, comptime format: []const u8, args: anytype) void {
    const message = stdz_mod.fmt.allocPrint(self.allocator, format, args) catch {
        self.logInfo("logInfof format failed");
        return;
    };
    defer self.allocator.free(message);
    self.logInfo(message);
}

pub fn logError(self: *Self, message: []const u8) void {
    self.vtable.logErrorFn(self.ptr, message);
}

pub fn logErrorf(self: *Self, comptime format: []const u8, args: anytype) void {
    const message = stdz_mod.fmt.allocPrint(self.allocator, format, args) catch {
        self.logError("logErrorf format failed");
        return;
    };
    defer self.allocator.free(message);
    self.logError(message);
}

pub fn parallel(self: *Self) void {
    if (self.is_parallel) return;
    self.is_parallel = true;
}

pub fn setTestHook(self: *Self, hook: TestHook) void {
    self.test_hook = hook;
}

pub fn timeout(self: *Self, ns: i64) void {
    self.vtable.timeoutFn(self, ns);
}

/// Starts a child run on this handle.
///
/// Callers must not start additional children after `wait()` has been called on
/// the same `T`.
pub fn run(self: *Self, child_name: []const u8, task: TestRunnerHandle) void {
    self.vtable.runFn(self, child_name, task);
}

/// Waits for all previously started child runs to finish.
///
/// This is idempotent and must be called before `deinit()`.
pub fn wait(self: *Self) bool {
    return self.vtable.waitFn(self);
}

fn formatMemoryUsage(buf: []u8, bytes: usize) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };

    if (bytes < 1024) {
        return stdz_mod.fmt.bufPrint(buf, "{d} B", .{bytes}) catch unreachable;
    }

    const bytes_u128: u128 = bytes;
    var unit_idx: usize = 0;
    var unit_size: u128 = 1;
    while (unit_idx + 1 < units.len and bytes_u128 >= unit_size * 1024) {
        unit_idx += 1;
        unit_size *= 1024;
    }

    var whole = bytes_u128 / unit_size;
    const remainder = bytes_u128 % unit_size;
    var frac = (remainder * 1000 + unit_size / 2) / unit_size;
    if (frac == 1000) {
        whole += 1;
        frac = 0;
        if (whole == 1024 and unit_idx + 1 < units.len) {
            whole = 1;
            unit_idx += 1;
        }
    }

    return stdz_mod.fmt.bufPrint(buf, "{d}.{d:0>3} {s}", .{ whole, frac, units[unit_idx] }) catch unreachable;
}

fn structuredLabelPadding(label: []const u8) []const u8 {
    const pad_len = if (label.len >= structured_label_width)
        1
    else
        structured_label_width - label.len + 1;
    return padding_spaces[0..pad_len];
}

pub fn new(comptime lib: type, comptime scope: @Type(.enum_literal)) Self {
    const ContextApi = context_mod.make(lib);
    const TestingAllocator = @import("TestingAllocator.zig");
    const run_log = lib.log.scoped(scope);

    const Impl = struct {
        name_buf: []u8,
        parent: ?*ImplSelf,
        allocator: lib.mem.Allocator,
        testing_allocator: *TestingAllocator,
        context_api: ContextApi,
        base_ctx: Context,
        timeout_ctx: ?Context = null,
        pending_runs: lib.ArrayList(*PendingRun) = .empty,
        started_ns: u64 = 0,
        body_finished_ns: u64 = 0,
        failure_ns: u64 = 0,
        finished_ns: u64 = 0,
        is_wait_done: bool = false,
        destroy_debug_tag: ?[]const u8 = null,

        state_mutex: lib.Thread.Mutex = .{},
        is_failed: bool = false,
        is_fatal: bool = false,

        const ImplSelf = @This();
        const PendingRun = struct {
            child: Self,
            runner: TestRunnerHandle,
            testing_allocator: TestingAllocator,
            ok: bool = false,
            worker: lib.Thread,
        };

        fn projectSpawnConfig(
            runner_config: stdz_mod.Thread.SpawnConfig,
            allocator: stdz_mod.mem.Allocator,
        ) lib.Thread.SpawnConfig {
            var config: lib.Thread.SpawnConfig = .{
                .allocator = runner_config.allocator orelse allocator,
            };
            if (runner_config.stack_size != 0) {
                config.stack_size = runner_config.stack_size;
            }
            if (@hasField(lib.Thread.SpawnConfig, "priority")) {
                config.priority = runner_config.priority;
            }
            if (@hasField(lib.Thread.SpawnConfig, "name")) {
                config.name = runner_config.name;
            }
            if (@hasField(lib.Thread.SpawnConfig, "core_id")) {
                config.core_id = runner_config.core_id;
            }
            return config;
        }

        fn createRoot() !Self {
            const ta = try lib.testing.allocator.create(TestingAllocator);
            errdefer lib.testing.allocator.destroy(ta);
            ta.* = TestingAllocator.init(lib.testing.allocator, null);

            const allocator = ta.allocator();
            const impl = try allocator.create(ImplSelf);
            errdefer allocator.destroy(impl);

            const name_buf = try allocator.dupe(u8, "");
            errdefer allocator.free(name_buf);

            var context_api = try ContextApi.init(allocator);
            errdefer context_api.deinit();

            const ctx = try context_api.withCancel(context_api.background());
            errdefer ctx.deinit();

            impl.* = .{
                .name_buf = name_buf,
                .parent = null,
                .allocator = allocator,
                .testing_allocator = ta,
                .context_api = context_api,
                .base_ctx = ctx,
                .timeout_ctx = null,
                .state_mutex = .{},
                .pending_runs = .empty,
                .started_ns = 0,
                .body_finished_ns = 0,
                .failure_ns = 0,
                .finished_ns = 0,
                .is_wait_done = false,
                .destroy_debug_tag = null,
                .is_failed = false,
                .is_fatal = false,
            };
            return Self.init(impl.name_buf, .{
                .ptr = impl,
                .allocator = allocator,
                .context = ctx,
                .vtable = &vtable,
            });
        }

        fn createChild(parent: *Self, child_name: []const u8) !Self {
            const parent_state = fromPtr(parent.ptr);
            const now_ns = currentTimestampNs();
            const relative_started_ns = if (now_ns <= parent_state.started_ns)
                parent.relative_started_ns
            else
                parent.relative_started_ns + (now_ns - parent_state.started_ns);
            const allocator = parent_state.allocator;

            const ta = try allocator.create(TestingAllocator);
            errdefer allocator.destroy(ta);
            ta.* = TestingAllocator.init(parent_state.testing_allocator.allocator(), null);

            const impl = try allocator.create(ImplSelf);
            errdefer allocator.destroy(impl);

            const name_buf = try lib.fmt.allocPrint(allocator, "{s}/{s}", .{
                parent_state.name_buf,
                child_name,
            });
            errdefer allocator.free(name_buf);

            var context_api = try ContextApi.init(allocator);
            errdefer context_api.deinit();

            const ctx = try context_api.withCancel(parent.ctx);
            errdefer ctx.deinit();

            impl.* = .{
                .name_buf = name_buf,
                .parent = parent_state,
                .allocator = allocator,
                .testing_allocator = ta,
                .context_api = context_api,
                .base_ctx = ctx,
                .timeout_ctx = null,
                .state_mutex = .{},
                .pending_runs = .empty,
                .started_ns = 0,
                .body_finished_ns = 0,
                .failure_ns = 0,
                .finished_ns = 0,
                .is_wait_done = false,
                .destroy_debug_tag = null,
                .is_failed = false,
                .is_fatal = false,
            };
            return Self.init(impl.name_buf, .{
                .ptr = impl,
                .allocator = allocator,
                .context = ctx,
                .relative_started_ns = relative_started_ns,
                .vtable = &vtable,
                .test_hook = parent.test_hook,
            });
        }

        fn fromPtr(ptr: *anyopaque) *ImplSelf {
            return @ptrCast(@alignCast(ptr));
        }

        fn destroyState(state: *ImplSelf) void {
            const testing_allocator = state.testing_allocator;
            const testing_allocator_owner = if (state.parent) |parent|
                parent.testing_allocator.allocator()
            else
                lib.testing.allocator;
            state.pending_runs.deinit(state.allocator);
            if (state.timeout_ctx) |timeout_ctx| {
                timeout_ctx.deinit();
            }
            state.base_ctx.deinit();
            state.context_api.deinit();
            state.allocator.free(state.name_buf);
            state.allocator.destroy(state);
            testing_allocator_owner.destroy(testing_allocator);
        }

        fn enableDestroyDebugFn(self: *Self, tag: []const u8) void {
            const state = fromPtr(self.ptr);
            state.destroy_debug_tag = tag;
        }

        fn destroyNeverStarted(self: *Self) void {
            const state = fromPtr(self.ptr);
            if (state.pending_runs.items.len != 0) {
                @panic("testing.T.destroyNeverStarted with pending subtests");
            }
            if (state.is_wait_done) {
                @panic("testing.T.destroyNeverStarted after wait");
            }
            destroyState(state);
            self.* = undefined;
        }

        fn deinitFn(self: *Self) void {
            const state = fromPtr(self.ptr);
            if (!state.is_wait_done) {
                @panic("testing.T.deinit requires explicit wait");
            }
            if (state.pending_runs.items.len != 0) {
                @panic("testing.T.deinit with pending subtests");
            }
            destroyState(state);
        }

        fn failed(self: *ImplSelf) bool {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            return self.is_failed;
        }

        fn recordFailure(self: *ImplSelf, failure_ns: u64) void {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            self.is_failed = true;
            if (self.failure_ns == 0) self.failure_ns = failure_ns;
        }

        fn recordFatal(self: *ImplSelf, failure_ns: u64) void {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            self.is_failed = true;
            self.is_fatal = true;
            if (self.failure_ns == 0) self.failure_ns = failure_ns;
        }

        fn fatal(self: *ImplSelf) bool {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            return self.is_fatal;
        }

        fn onCreatedFn(self: *Self) void {
            const state = fromPtr(self.ptr);
            state.started_ns = currentTimestampNs();
            state.body_finished_ns = 0;
            state.failure_ns = 0;
            state.finished_ns = 0;
            state.is_wait_done = false;
            logOpened(state, nsToMs(self.relative_started_ns));
        }

        fn onDestroyedFn(self: *Self) void {
            const state = fromPtr(self.ptr);
            if (!state.is_wait_done) return;
            const delta_ns = elapsedNsBetween(state.started_ns, state.finished_ns);
            const total_ms = nsToMs(self.relative_started_ns + delta_ns);
            const delta_ms = nsToMs(delta_ns);
            const success = !state.failed();
            logFinished(state, success, total_ms, delta_ms);
        }

        fn logFatalFn(self: *Self, message: []const u8) void {
            const state = fromPtr(self.ptr);
            state.recordFatal(currentTimestampNs());
            const label = state.name_buf;
            if (message.len != 0) {
                if (label.len == 0) {
                    run_log.err("{s}{s}{s} {s}", .{ fail_color, fail_marker, color_reset, message });
                } else {
                    run_log.err("{s}{s} {s}{s}{s}{s}", .{
                        fail_color,
                        fail_marker,
                        label,
                        color_reset,
                        structuredLabelPadding(label),
                        message,
                    });
                }
            }
            self.ctx.cancelWithCause(error.TestFailed);
        }

        fn timeoutFn(self: *Self, ns: i64) void {
            const state = fromPtr(self.ptr);
            if (state.timeout_ctx != null) return;

            const timeout_ctx = state.context_api.withTimeout(self.ctx, ns) catch {
                self.logFatal("timeout setup failed");
                return;
            };
            state.timeout_ctx = timeout_ctx;
            self.ctx = timeout_ctx;
        }

        fn logInfoFn(ptr: *anyopaque, message: []const u8) void {
            const self = fromPtr(ptr);
            const label = self.name_buf;
            if (label.len == 0) {
                run_log.info("{s}", .{message});
            } else {
                run_log.info("{s}{s}{s}", .{
                    label,
                    structuredLabelPadding(label),
                    message,
                });
            }
        }

        fn logErrorFn(ptr: *anyopaque, message: []const u8) void {
            const self = fromPtr(ptr);
            self.recordFailure(currentTimestampNs());
            const label = self.name_buf;
            if (message.len != 0) {
                if (label.len == 0) {
                    run_log.err("{s}{s}{s} {s}", .{ fail_color, fail_marker, color_reset, message });
                } else {
                    run_log.err("{s}{s} {s}{s}{s}{s}", .{
                        fail_color,
                        fail_marker,
                        label,
                        color_reset,
                        structuredLabelPadding(label),
                        message,
                    });
                }
            }
        }

        fn currentTimestampNs() u64 {
            const now_ns = lib.time.nanoTimestamp();
            return if (now_ns <= 0) 0 else @intCast(now_ns);
        }

        fn elapsedNsBetween(started_ns: u64, finished_ns: u64) u64 {
            return if (finished_ns <= started_ns) 0 else finished_ns - started_ns;
        }

        fn nsToMs(ns: u64) u64 {
            return ns / @as(u64, lib.time.ns_per_ms);
        }

        fn logOpened(self: *ImplSelf, total_ms: u64) void {
            if (self.parent == null) return;
            const label = self.name_buf;
            run_log.info("{s}{s} {s}{s}{s}start at {d}.{d:0>1}s", .{
                open_color,
                open_marker,
                label,
                color_reset,
                structuredLabelPadding(label),
                total_ms / 1000,
                (total_ms % 1000) / 100,
            });
        }

        fn reportedPeakLiveBytes(self: *ImplSelf) usize {
            return self.testing_allocator.peakLiveBytes();
        }

        fn logFinished(self: *ImplSelf, success: bool, total_ms: u64, delta_ms: u64) void {
            const peak_live_bytes = self.reportedPeakLiveBytes();
            var peak_live_bytes_buf: [32]u8 = undefined;
            const peak_live_bytes_text = formatMemoryUsage(&peak_live_bytes_buf, peak_live_bytes);
            const is_root = self.parent == null;
            const label = self.name_buf;
            if (success) {
                if (is_root) {
                    run_log.info("{s}{s} {s}{s}{s}done at {d}.{d:0>1}s, {d}ms, {s}", .{
                        done_color,
                        done_marker,
                        summary_label,
                        color_reset,
                        structuredLabelPadding(summary_label),
                        total_ms / 1000,
                        (total_ms % 1000) / 100,
                        delta_ms,
                        peak_live_bytes_text,
                    });
                } else {
                    run_log.info("{s}{s} {s}{s}{s}done at {d}.{d:0>1}s, {d}ms, {s}", .{
                        done_color,
                        done_marker,
                        label,
                        color_reset,
                        structuredLabelPadding(label),
                        total_ms / 1000,
                        (total_ms % 1000) / 100,
                        delta_ms,
                        peak_live_bytes_text,
                    });
                }
            } else {
                if (is_root) {
                    run_log.err("{s}{s} {s}{s}{s}failed at {d}.{d:0>1}s, {d}ms, {s}", .{
                        fail_color,
                        fail_marker,
                        summary_label,
                        color_reset,
                        structuredLabelPadding(summary_label),
                        total_ms / 1000,
                        (total_ms % 1000) / 100,
                        delta_ms,
                        peak_live_bytes_text,
                    });
                } else {
                    run_log.err("{s}{s} {s}{s}{s}failed at {d}.{d:0>1}s, {d}ms, {s}", .{
                        fail_color,
                        fail_marker,
                        label,
                        color_reset,
                        structuredLabelPadding(label),
                        total_ms / 1000,
                        (total_ms % 1000) / 100,
                        delta_ms,
                        peak_live_bytes_text,
                    });
                }
            }
        }

        fn waitPending(parent: *Self, pending: *PendingRun) bool {
            const child_state = fromPtr(pending.child.ptr);
            const parent_state = fromPtr(parent.ptr);
            const run_allocator = pending.testing_allocator.allocator();
            pending.worker.join();
            pending.runner.deinit(run_allocator);
            if (child_state.failed()) {
                parent_state.recordFailure(if (child_state.failure_ns != 0)
                    child_state.failure_ns
                else
                    currentTimestampNs());
            }
            const ok = pending.ok and !child_state.failed();
            pending.child.deinit();
            parent_state.allocator.destroy(pending);
            return ok;
        }

        fn runFn(self: *Self, child_name: []const u8, runner: TestRunnerHandle) void {
            const self_state = fromPtr(self.ptr);
            if (self_state.fatal()) {
                runner.deinit(self_state.allocator);
                return;
            }

            var child = createChild(self, child_name) catch {
                runner.deinit(self_state.allocator);
                self.logFatal("subtest init failed");
                return;
            };

            var configured_runner = runner;
            if (child.test_hook.beforeRun) |before_run| {
                before_run(&child, &configured_runner);
            }

            const pending = self_state.allocator.create(PendingRun) catch null orelse {
                var child_copy = child;
                configured_runner.deinit(self_state.allocator);
                destroyNeverStarted(&child_copy);
                self.logFatal("subtest state alloc failed");
                return;
            };

            pending.* = .{
                .child = child,
                .runner = configured_runner,
                .testing_allocator = TestingAllocator.init(fromPtr(child.ptr).testing_allocator.allocator(), configured_runner.memory_limit),
                .worker = undefined,
            };
            const Worker = struct {
                fn main(pending_run: *PendingRun) void {
                    const child_state = fromPtr(pending_run.child.ptr);
                    const run_allocator = pending_run.testing_allocator.allocator();
                    const run_ok = pending_run.runner.run(&pending_run.child, run_allocator);
                    child_state.body_finished_ns = currentTimestampNs();
                    const wait_ok = pending_run.child.wait();
                    const ok = run_ok and wait_ok;
                    if (!ok and !child_state.failed()) {
                        pending_run.child.logError("test returned false");
                    }
                    pending_run.ok = ok and !child_state.failed();
                }
            };

            const child_state = fromPtr(child.ptr);
            const child_allocator = child_state.testing_allocator.allocator();
            const dup_config = projectSpawnConfig(configured_runner.spawn_config, child_allocator);

            pending.worker = lib.Thread.spawn(dup_config, Worker.main, .{pending}) catch |err| {
                const child_label = child.name();
                run_log.err("subtest Thread.spawn error: {s} (child {s})", .{
                    @errorName(err),
                    child_label,
                });
                run_log.err("{s}{s} {s}{s}{s}subtest spawn failed", .{
                    fail_color,
                    fail_marker,
                    child_label,
                    color_reset,
                    structuredLabelPadding(child_label),
                });
                pending.runner.deinit(pending.testing_allocator.allocator());
                destroyNeverStarted(&pending.child);
                self_state.allocator.destroy(pending);
                self.logFatal("subtest spawn failed");
                return;
            };

            if (!self.is_parallel) {
                _ = waitPending(self, pending);
                return;
            }

            self_state.pending_runs.append(self_state.allocator, pending) catch {
                _ = waitPending(self, pending);
                self.logFatal("parallel subtest append failed");
                return;
            };
        }

        fn waitFn(self: *Self) bool {
            const state = fromPtr(self.ptr);
            if (state.is_wait_done) {
                return !state.failed();
            }

            var ok = !state.failed();
            var waited_on_pending = false;
            while (state.pending_runs.items.len != 0) {
                waited_on_pending = true;
                const pending = state.pending_runs.orderedRemove(0);
                ok = waitPending(self, pending) and ok;
            }

            state.finished_ns = if (state.failure_ns != 0)
                state.failure_ns
            else if (!waited_on_pending and state.body_finished_ns != 0)
                state.body_finished_ns
            else
                currentTimestampNs();
            state.is_wait_done = true;
            return ok and !state.failed();
        }

        const vtable: VTable = .{
            .onCreatedFn = onCreatedFn,
            .onDestroyedFn = onDestroyedFn,
            .deinitFn = deinitFn,
            .enableDestroyDebugFn = enableDestroyDebugFn,
            .logFatalFn = logFatalFn,
            .timeoutFn = timeoutFn,
            .logInfoFn = logInfoFn,
            .logErrorFn = logErrorFn,
            .runFn = runFn,
            .waitFn = waitFn,
        };
    };

    return Impl.createRoot() catch @panic("testing.T.make failed");
}

pub fn TestRunner(comptime lib: type) TestRunnerHandle {
    if (builtin.target.os.tag == .freestanding) {
        const Runner = struct {
            pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
                _ = self;
                _ = allocator;
            }

            pub fn run(self: *@This(), t: *Self, allocator: lib.mem.Allocator) bool {
                _ = self;
                _ = t;
                _ = allocator;
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
        return TestRunnerHandle.make(Runner).new(&Holder.runner);
    }

    const TestCase = struct {
        fn testFormatMemoryUsage() !void {
            const std = @import("std");

            var buf: [32]u8 = undefined;

            try std.testing.expectEqualStrings("0 B", formatMemoryUsage(&buf, 0));
            try std.testing.expectEqualStrings("1023 B", formatMemoryUsage(&buf, 1023));
            try std.testing.expectEqualStrings("1.000 KiB", formatMemoryUsage(&buf, 1024));
            try std.testing.expectEqualStrings("1.500 KiB", formatMemoryUsage(&buf, 1536));
            try std.testing.expectEqualStrings("15.640 MiB", formatMemoryUsage(&buf, 16399707));
        }
        fn testContextCancelLogs() !void {
            const std = @import("std");
            const stdz = @import("stdz");

            const Support = struct {
                var entries: std.ArrayListUnmanaged([]u8) = .{};
                var mutex: std.Thread.Mutex = .{};
                var now_ns = std.atomic.Value(u64).init(0);
                var stage = std.atomic.Value(u32).init(0);

                fn reset() void {
                    mutex.lock();
                    defer mutex.unlock();
                    for (entries.items) |entry| {
                        std.testing.allocator.free(entry);
                    }
                    entries.deinit(std.testing.allocator);
                    entries = .{};
                    now_ns.store(0, .release);
                    stage.store(0, .release);
                }

                fn append(comptime format: []const u8, args: anytype) void {
                    const message = std.fmt.allocPrint(std.testing.allocator, format, args) catch @panic("OOM");
                    mutex.lock();
                    defer mutex.unlock();
                    entries.append(std.testing.allocator, message) catch @panic("OOM");
                }

                fn advance(ns: u64) void {
                    _ = now_ns.fetchAdd(ns, .acq_rel);
                }

                fn timestampNs() u64 {
                    return now_ns.load(.acquire);
                }

                fn setStage(value: u32) void {
                    stage.store(value, .release);
                }

                fn waitForStage(target: u32) void {
                    while (stage.load(.acquire) < target) {}
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

            const TestThread = struct {
                pub const SpawnConfig = std.Thread.SpawnConfig;
                pub const Mutex = std.Thread.Mutex;
                pub const RwLock = std.Thread.RwLock;
                const ThreadSelf = @This();
                pub const Condition = struct {
                    inner: std.Thread.Condition = .{},

                    pub fn wait(self: *Condition, mutex: *Mutex) void {
                        self.inner.wait(mutex);
                    }

                    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
                        self.inner.timedWait(mutex, timeout_ns) catch return error.Timeout;
                    }

                    pub fn signal(self: *Condition) void {
                        self.inner.signal();
                    }

                    pub fn broadcast(self: *Condition) void {
                        self.inner.broadcast();
                    }
                };

                inner: std.Thread,

                pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) !ThreadSelf {
                    return .{
                        .inner = try std.Thread.spawn(config, f, args),
                    };
                }

                pub fn join(self: ThreadSelf) void {
                    self.inner.join();
                }

                pub fn detach(self: ThreadSelf) void {
                    self.inner.detach();
                }

                pub fn sleep(ns: u64) void {
                    Support.advance(ns);
                }
            };

            const TestLib = struct {
                pub const mem = stdz.mem;
                pub const fmt = stdz.fmt;
                pub const Thread = TestThread;
                pub const log = CapturingLog;
                pub fn ArrayList(comptime T: type) type {
                    return std.ArrayList(T);
                }
                pub const testing = struct {
                    pub const allocator = std.testing.allocator;
                };
                pub const time = struct {
                    pub const ns_per_ms = std.time.ns_per_ms;
                    pub const Instant = std.time.Instant;

                    pub fn nanoTimestamp() i128 {
                        return Support.timestampNs();
                    }

                    pub fn milliTimestamp() i64 {
                        return @intCast(@divFloor(Support.timestampNs(), std.time.ns_per_ms));
                    }
                };
            };

            const TaskRunner = struct {
                fn make(comptime run_fn: anytype, memory_limit: ?usize) TestRunnerHandle {
                    const Runner = struct {
                        memory_limit: ?usize,

                        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                            _ = self;
                            _ = allocator;
                        }

                        pub fn run(self: *@This(), t: *Self, allocator: stdz.mem.Allocator) bool {
                            _ = self;
                            var arg_byte: u8 = 0;
                            return run_fn(t, allocator, @ptrCast(&arg_byte));
                        }

                        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                            _ = allocator;
                            std.testing.allocator.destroy(self);
                        }
                    };

                    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
                    runner.* = .{ .memory_limit = memory_limit };
                    return TestRunnerHandle.make(Runner).new(runner);
                }
            };

            const ChildTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    TestLib.Thread.sleep(40 * TestLib.time.ns_per_ms);
                    t.logFatal("child fatal");
                    const cause = t.context().err() orelse return false;
                    return cause == error.TestFailed;
                }
            };

            const NestedTimeoutTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    t.run("leaf", TaskRunner.make(struct {
                        fn runLeaf(leaf: *Self, alloc: stdz_mod.mem.Allocator, leaf_args: *anyopaque) bool {
                            _ = alloc;
                            _ = leaf_args;
                            TestLib.Thread.sleep(300 * TestLib.time.ns_per_ms);
                            leaf.context().cancelWithCause(error.TestTimeout);
                            leaf.logError("leaf timeout");
                            const cause = leaf.context().err() orelse return false;
                            return cause == error.TestTimeout;
                        }
                    }.runLeaf, null));
                    return t.wait();
                }
            };

            const ParallelFastTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = t;
                    _ = allocator;
                    _ = args;
                    Support.advance(100 * TestLib.time.ns_per_ms);
                    Support.setStage(1);
                    Support.waitForStage(2);
                    Support.advance(200 * TestLib.time.ns_per_ms);
                    return true;
                }
            };

            const ParallelSlowTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    Support.waitForStage(1);
                    Support.advance(300 * TestLib.time.ns_per_ms);
                    t.logError("slow timeout");
                    Support.setStage(2);
                    return false;
                }
            };

            const ComplexLeafOkTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = t;
                    _ = allocator;
                    _ = args;
                    TestLib.Thread.sleep(50 * TestLib.time.ns_per_ms);
                    return true;
                }
            };

            const ComplexLeafErrTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    TestLib.Thread.sleep(20 * TestLib.time.ns_per_ms);
                    t.logError("leaf err");
                    return false;
                }
            };

            const ComplexFastTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = t;
                    _ = allocator;
                    _ = args;
                    Support.advance(30 * TestLib.time.ns_per_ms);
                    Support.setStage(1);
                    Support.waitForStage(2);
                    Support.advance(80 * TestLib.time.ns_per_ms);
                    return true;
                }
            };

            const ComplexSlowTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    Support.waitForStage(1);
                    Support.advance(60 * TestLib.time.ns_per_ms);
                    t.logError("slow timeout");
                    Support.setStage(2);
                    return false;
                }
            };

            const ComplexDeepFatalTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    TestLib.Thread.sleep(40 * TestLib.time.ns_per_ms);
                    t.logFatal("deep fatal");
                    const cause = t.context().err() orelse return false;
                    return cause == error.TestFailed;
                }
            };

            const ComplexNestedTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    t.run("deep", TaskRunner.make(ComplexDeepFatalTask.run, null));
                    return t.wait();
                }
            };

            const ComplexSuiteTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    t.run("leaf_ok", TaskRunner.make(ComplexLeafOkTask.run, null));
                    t.run("leaf_err", TaskRunner.make(ComplexLeafErrTask.run, null));

                    t.run("nested", TaskRunner.make(ComplexNestedTask.run, null));

                    t.parallel();
                    t.run("fast", TaskRunner.make(ComplexFastTask.run, null));
                    Support.waitForStage(1);
                    t.run("slow", TaskRunner.make(ComplexSlowTask.run, null));
                    return t.wait();
                }
            };

            const Helper = struct {
                fn makeRunner(comptime run_fn: anytype, memory_limit: ?usize) TestRunnerHandle {
                    const Runner = struct {
                        memory_limit: ?usize,

                        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                            _ = self;
                            _ = allocator;
                        }

                        pub fn run(self: *@This(), t: *Self, allocator: stdz.mem.Allocator) bool {
                            _ = self;
                            var arg_byte: u8 = 0;
                            return run_fn(t, allocator, @ptrCast(&arg_byte));
                        }

                        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                            _ = allocator;
                            std.testing.allocator.destroy(self);
                        }
                    };

                    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
                    runner.* = .{ .memory_limit = memory_limit };
                    return TestRunnerHandle.make(Runner).new(runner);
                }

                fn appendNormalizedLine(bytes: *std.ArrayList(u8), line: []const u8) !void {
                    var plain_line = std.ArrayList(u8).empty;
                    defer plain_line.deinit(std.testing.allocator);

                    var i: usize = 0;
                    while (i < line.len) {
                        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
                            i += 2;
                            while (i < line.len and line[i] != 'm') : (i += 1) {}
                            if (i < line.len) i += 1;
                            continue;
                        }
                        try plain_line.append(std.testing.allocator, line[i]);
                        i += 1;
                    }

                    const plain = plain_line.items;
                    var compact_line = std.ArrayList(u8).empty;
                    defer compact_line.deinit(std.testing.allocator);
                    const normalized_plain = blk: {
                        if (std.mem.startsWith(u8, plain, ">>> ") or
                            std.mem.startsWith(u8, plain, "<<< ") or
                            std.mem.startsWith(u8, plain, "!!! "))
                        {
                            const prefix = plain[0..4];
                            const rest = plain[4..];
                            const split_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse break :blk plain;
                            const label = rest[0..split_idx];
                            const suffix = std.mem.trimLeft(u8, rest[split_idx..], " ");
                            try compact_line.appendSlice(std.testing.allocator, prefix);
                            try compact_line.appendSlice(std.testing.allocator, label);
                            try compact_line.append(std.testing.allocator, ' ');
                            try compact_line.appendSlice(std.testing.allocator, suffix);
                            break :blk compact_line.items;
                        }
                        break :blk plain;
                    };
                    const event_idx = std.mem.indexOf(u8, normalized_plain, " done at ") orelse
                        std.mem.indexOf(u8, normalized_plain, " failed at ");
                    if (event_idx) |idx| {
                        const prefix = std.mem.trimRight(u8, normalized_plain[0..idx], " ");
                        const suffix = normalized_plain[idx + 1 ..];
                        if (std.mem.indexOf(u8, suffix, "ms, ")) |ms_idx| {
                            try bytes.appendSlice(std.testing.allocator, prefix);
                            try bytes.append(std.testing.allocator, ' ');
                            try bytes.appendSlice(std.testing.allocator, suffix[0 .. ms_idx + 4]);
                            try bytes.appendSlice(std.testing.allocator, "<mem>");
                            return;
                        }
                        try bytes.appendSlice(std.testing.allocator, prefix);
                        try bytes.append(std.testing.allocator, ' ');
                        try bytes.appendSlice(std.testing.allocator, suffix);
                        return;
                    }
                    try bytes.appendSlice(std.testing.allocator, normalized_plain);
                }

                fn normalizedLog() ![]u8 {
                    const actual_log = try Support.joinedLog(std.testing.allocator);
                    defer std.testing.allocator.free(actual_log);

                    var normalized = std.ArrayList(u8).empty;
                    errdefer normalized.deinit(std.testing.allocator);

                    var lines = std.mem.splitScalar(u8, actual_log, '\n');
                    var first = true;
                    while (lines.next()) |line| {
                        if (!first) try normalized.append(std.testing.allocator, '\n');
                        try appendNormalizedLine(&normalized, line);
                        first = false;
                    }
                    return normalized.toOwnedSlice(std.testing.allocator);
                }

                fn expectLog(expected_log: []const u8) !void {
                    const actual_log = try normalizedLog();
                    defer std.testing.allocator.free(actual_log);
                    try std.testing.expectEqualStrings(expected_log, actual_log);
                }

                fn expectOneOfLogs(expected_a: []const u8, expected_b: []const u8) !void {
                    const actual_log = try normalizedLog();
                    defer std.testing.allocator.free(actual_log);
                    if (std.mem.eql(u8, expected_a, actual_log)) return;
                    if (std.mem.eql(u8, expected_b, actual_log)) return;
                    try std.testing.expectEqualStrings(expected_a, actual_log);
                }
            };

            Support.reset();
            defer Support.reset();

            {
                var root = new(TestLib, .test_run);
                TestLib.Thread.sleep(220 * TestLib.time.ns_per_ms);

                root.run("child", TaskRunner.make(ChildTask.run, null));
                try std.testing.expect(!root.wait());
                root.deinit();

                const expected_log =
                    \\>>> /child start at 0.2s
                    \\!!! /child child fatal
                    \\!!! /child failed at 0.2s, 40ms, <mem>
                    \\!!! summary failed at 0.2s, 260ms, <mem>
                ;

                try Helper.expectLog(expected_log);
            }

            Support.reset();

            {
                var root = new(TestLib, .test_run);
                TestLib.Thread.sleep(100 * TestLib.time.ns_per_ms);

                root.run("parent", TaskRunner.make(NestedTimeoutTask.run, null));
                try std.testing.expect(!root.wait());
                root.deinit();

                const expected_log =
                    \\>>> /parent start at 0.1s
                    \\>>> /parent/leaf start at 0.1s
                    \\!!! /parent/leaf leaf timeout
                    \\!!! /parent/leaf failed at 0.4s, 300ms, <mem>
                    \\!!! /parent failed at 0.4s, 300ms, <mem>
                    \\!!! summary failed at 0.4s, 400ms, <mem>
                ;

                try Helper.expectLog(expected_log);
            }

            Support.reset();

            {
                var root = new(TestLib, .test_run);
                root.parallel();

                root.run("fast", TaskRunner.make(ParallelFastTask.run, null));
                Support.waitForStage(1);
                root.run("slow", TaskRunner.make(ParallelSlowTask.run, null));

                try std.testing.expect(!root.wait());
                root.deinit();

                const expected_log_a =
                    \\>>> /fast start at 0.0s
                    \\>>> /slow start at 0.1s
                    \\!!! /slow slow timeout
                    \\<<< /fast done at 0.6s, 600ms, <mem>
                    \\!!! /slow failed at 0.4s, 300ms, <mem>
                    \\!!! summary failed at 0.4s, 400ms, <mem>
                ;
                const expected_log_b =
                    \\>>> /fast start at 0.0s
                    \\>>> /slow start at 0.1s
                    \\!!! /slow slow timeout
                    \\<<< /fast done at 0.6s, 600ms, <mem>
                    \\!!! /slow failed at 0.6s, 500ms, <mem>
                    \\!!! summary failed at 0.6s, 600ms, <mem>
                ;

                try Helper.expectOneOfLogs(expected_log_a, expected_log_b);
            }

            Support.reset();

            {
                var root = new(TestLib, .test_run);
                TestLib.Thread.sleep(100 * TestLib.time.ns_per_ms);

                root.run("suite", TaskRunner.make(ComplexSuiteTask.run, null));
                try std.testing.expect(!root.wait());
                root.deinit();

                const expected_log =
                    \\>>> /suite start at 0.1s
                    \\>>> /suite/leaf_ok start at 0.1s
                    \\<<< /suite/leaf_ok done at 0.1s, 50ms, <mem>
                    \\>>> /suite/leaf_err start at 0.1s
                    \\!!! /suite/leaf_err leaf err
                    \\!!! /suite/leaf_err failed at 0.1s, 20ms, <mem>
                    \\>>> /suite/nested start at 0.1s
                    \\>>> /suite/nested/deep start at 0.1s
                    \\!!! /suite/nested/deep deep fatal
                    \\!!! /suite/nested/deep failed at 0.2s, 40ms, <mem>
                    \\!!! /suite/nested failed at 0.2s, 40ms, <mem>
                    \\>>> /suite/fast start at 0.2s
                    \\>>> /suite/slow start at 0.2s
                    \\!!! /suite/slow slow timeout
                    \\<<< /suite/fast done at 0.3s, 170ms, <mem>
                    \\!!! /suite/slow failed at 0.3s, 60ms, <mem>
                    \\!!! /suite failed at 0.1s, 70ms, <mem>
                    \\!!! summary failed at 0.1s, 170ms, <mem>
                ;

                try Helper.expectLog(expected_log);
            }
        }
        fn testTimeout() !void {
            const std = @import("std");
            const stdz = @import("stdz");

            const Support = struct {
                var entries: std.ArrayListUnmanaged([]u8) = .{};
                var mutex: std.Thread.Mutex = .{};
                var now_ns = std.atomic.Value(u64).init(0);
                var stage = std.atomic.Value(u32).init(0);

                fn reset() void {
                    mutex.lock();
                    defer mutex.unlock();
                    for (entries.items) |entry| {
                        std.testing.allocator.free(entry);
                    }
                    entries.deinit(std.testing.allocator);
                    entries = .{};
                    now_ns.store(0, .release);
                    stage.store(0, .release);
                }

                fn append(comptime format: []const u8, args: anytype) void {
                    const message = std.fmt.allocPrint(std.testing.allocator, format, args) catch @panic("OOM");
                    mutex.lock();
                    defer mutex.unlock();
                    entries.append(std.testing.allocator, message) catch @panic("OOM");
                }

                fn advance(ns: u64) void {
                    _ = now_ns.fetchAdd(ns, .acq_rel);
                }

                fn timestampNs() u64 {
                    return now_ns.load(.acquire);
                }

                fn setStage(value: u32) void {
                    stage.store(value, .release);
                }

                fn waitForStage(target: u32) void {
                    while (stage.load(.acquire) < target) std.Thread.yield() catch {};
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

            const TestThread = struct {
                pub const SpawnConfig = std.Thread.SpawnConfig;
                pub const Mutex = std.Thread.Mutex;
                pub const RwLock = std.Thread.RwLock;
                const ThreadSelf = @This();
                pub const Condition = struct {
                    inner: std.Thread.Condition = .{},

                    pub fn wait(self: *Condition, mutex: *Mutex) void {
                        self.inner.wait(mutex);
                    }

                    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
                        self.inner.timedWait(mutex, timeout_ns) catch return error.Timeout;
                    }

                    pub fn signal(self: *Condition) void {
                        self.inner.signal();
                    }

                    pub fn broadcast(self: *Condition) void {
                        self.inner.broadcast();
                    }
                };

                inner: std.Thread,

                pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) !ThreadSelf {
                    return .{
                        .inner = try std.Thread.spawn(config, f, args),
                    };
                }

                pub fn join(self: ThreadSelf) void {
                    self.inner.join();
                }

                pub fn detach(self: ThreadSelf) void {
                    self.inner.detach();
                }

                pub fn sleep(ns: u64) void {
                    Support.advance(ns);
                    std.Thread.sleep(ns);
                }
            };

            const TestLib = struct {
                pub const mem = stdz.mem;
                pub const fmt = stdz.fmt;
                pub const Thread = TestThread;
                pub const log = CapturingLog;
                pub fn ArrayList(comptime Elem: type) type {
                    return std.ArrayList(Elem);
                }
                pub const testing = struct {
                    pub const allocator = std.testing.allocator;
                };
                pub const time = struct {
                    pub const ns_per_ms = std.time.ns_per_ms;
                    pub const Instant = std.time.Instant;

                    pub fn nanoTimestamp() i128 {
                        return Support.timestampNs();
                    }

                    pub fn milliTimestamp() i64 {
                        return @intCast(@divFloor(Support.timestampNs(), std.time.ns_per_ms));
                    }
                };
            };

            const TaskRunner = struct {
                fn make(comptime run_fn: anytype, memory_limit: ?usize) TestRunnerHandle {
                    const Runner = struct {
                        memory_limit: ?usize,

                        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                            _ = self;
                            _ = allocator;
                        }

                        pub fn run(self: *@This(), t: *Self, allocator: stdz.mem.Allocator) bool {
                            _ = self;
                            var arg_byte: u8 = 0;
                            return run_fn(t, allocator, @ptrCast(&arg_byte));
                        }

                        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                            _ = allocator;
                            std.testing.allocator.destroy(self);
                        }
                    };

                    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
                    runner.* = .{ .memory_limit = memory_limit };
                    return TestRunnerHandle.make(Runner).new(runner);
                }
            };

            const suite_timeout_ns: i64 = 150 * TestLib.time.ns_per_ms;
            const nested_timeout_ns: i64 = 40 * TestLib.time.ns_per_ms;
            const branch_timeout_ns: i64 = 30 * TestLib.time.ns_per_ms;

            const ImmediateTimeoutTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    const deadline = t.context().deadline() orelse {
                        t.logError("immediate missing deadline");
                        return false;
                    };
                    if (deadline != 0) {
                        t.logError("immediate deadline mismatch");
                        return false;
                    }
                    const cause = t.context().err() orelse {
                        t.logError("immediate missing err");
                        return false;
                    };
                    if (cause != error.DeadlineExceeded) {
                        t.logError("immediate wrong err");
                        return false;
                    }
                    t.logError("immediate timeout");
                    return false;
                }
            };

            const NestedLeafFastTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    const deadline = t.context().deadline() orelse {
                        t.logError("fast leaf missing deadline");
                        return false;
                    };
                    if (deadline != @as(i128, nested_timeout_ns)) {
                        t.logError("fast leaf deadline mismatch");
                        return false;
                    }
                    TestLib.Thread.sleep(10 * TestLib.time.ns_per_ms);
                    if (t.context().err() != null) {
                        t.logError("fast leaf should stay active");
                        return false;
                    }
                    return true;
                }
            };

            const NestedLeafSlowTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    const deadline = t.context().deadline() orelse {
                        t.logError("leaf timeout missing deadline");
                        return false;
                    };
                    if (deadline != @as(i128, nested_timeout_ns)) {
                        t.logError("leaf timeout deadline mismatch");
                        return false;
                    }
                    TestLib.Thread.sleep(70 * TestLib.time.ns_per_ms);
                    const cause = t.context().err() orelse {
                        t.logError("leaf timeout missing err");
                        return false;
                    };
                    if (cause != error.DeadlineExceeded) {
                        t.logError("leaf timeout wrong err");
                        return false;
                    }
                    t.logError("leaf timeout");
                    return false;
                }
            };

            const NestedTimeoutTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    const inherited = t.context().deadline() orelse {
                        t.logError("nested missing inherited deadline");
                        return false;
                    };
                    if (inherited != @as(i128, suite_timeout_ns)) {
                        t.logError("nested inherited deadline mismatch");
                        return false;
                    }
                    t.timeout(nested_timeout_ns);
                    const first_deadline = t.context().deadline() orelse {
                        t.logError("nested timeout missing deadline");
                        return false;
                    };
                    if (first_deadline != @as(i128, nested_timeout_ns)) {
                        t.logError("nested timeout deadline mismatch");
                        return false;
                    }
                    t.timeout(90 * TestLib.time.ns_per_ms);
                    const second_deadline = t.context().deadline() orelse {
                        t.logError("nested second timeout missing deadline");
                        return false;
                    };
                    if (second_deadline != @as(i128, nested_timeout_ns)) {
                        t.logError("nested second timeout override");
                        return false;
                    }
                    t.run("leaf_fast", TaskRunner.make(NestedLeafFastTask.run, null));
                    t.run("leaf_slow", TaskRunner.make(NestedLeafSlowTask.run, null));
                    return t.wait();
                }
            };

            const ParallelFastTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    const deadline = t.context().deadline() orelse {
                        t.logError("parallel fast missing deadline");
                        return false;
                    };
                    if (deadline != @as(i128, suite_timeout_ns)) {
                        t.logError("parallel fast deadline mismatch");
                        return false;
                    }
                    TestLib.Thread.sleep(10 * TestLib.time.ns_per_ms);
                    if (t.context().err() != null) {
                        t.logError("parallel fast should stay active");
                        return false;
                    }
                    Support.setStage(1);
                    return true;
                }
            };

            const ParallelSlowTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    Support.waitForStage(1);
                    const deadline = t.context().deadline() orelse {
                        t.logError("parallel slow missing deadline");
                        return false;
                    };
                    if (deadline != @as(i128, suite_timeout_ns)) {
                        t.logError("parallel slow deadline mismatch");
                        return false;
                    }
                    TestLib.Thread.sleep(70 * TestLib.time.ns_per_ms);
                    const cause = t.context().err() orelse {
                        t.logError("parallel timeout missing err");
                        return false;
                    };
                    if (cause != error.DeadlineExceeded) {
                        t.logError("parallel timeout wrong err");
                        return false;
                    }
                    t.logError("parallel timeout");
                    return false;
                }
            };

            const ComplexTimeoutSuiteTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    const inherited = t.context().deadline() orelse {
                        t.logError("suite missing inherited deadline");
                        return false;
                    };
                    if (inherited != @as(i128, suite_timeout_ns)) {
                        t.logError("suite inherited deadline mismatch");
                        return false;
                    }
                    t.run("nested", TaskRunner.make(NestedTimeoutTask.run, null));
                    t.parallel();
                    t.run("fast", TaskRunner.make(ParallelFastTask.run, null));
                    Support.waitForStage(1);
                    t.run("slow", TaskRunner.make(ParallelSlowTask.run, null));
                    return t.wait();
                }
            };

            const ScopedTimedLeafTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    const deadline = t.context().deadline() orelse {
                        t.logError("branch timeout missing deadline");
                        return false;
                    };
                    if (deadline != @as(i128, branch_timeout_ns)) {
                        t.logError("branch timeout deadline mismatch");
                        return false;
                    }
                    TestLib.Thread.sleep(50 * TestLib.time.ns_per_ms);
                    const cause = t.context().err() orelse {
                        t.logError("branch timeout missing err");
                        return false;
                    };
                    if (cause != error.DeadlineExceeded) {
                        t.logError("branch timeout wrong err");
                        return false;
                    }
                    t.logError("branch timeout");
                    return false;
                }
            };

            const ScopedTimedBranchTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    if (t.context().deadline() != null) {
                        t.logError("timed branch should start without deadline");
                        return false;
                    }
                    t.timeout(branch_timeout_ns);
                    const deadline = t.context().deadline() orelse {
                        t.logError("timed branch missing deadline");
                        return false;
                    };
                    if (deadline != @as(i128, branch_timeout_ns)) {
                        t.logError("timed branch deadline mismatch");
                        return false;
                    }
                    t.run("timed_leaf", TaskRunner.make(ScopedTimedLeafTask.run, null));
                    return t.wait();
                }
            };

            const ScopedPlainBranchTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    if (t.context().deadline() != null) {
                        t.logError("plain branch inherited timeout");
                        return false;
                    }
                    TestLib.Thread.sleep(10 * TestLib.time.ns_per_ms);
                    if (t.context().err() != null) {
                        t.logError("plain branch canceled");
                        return false;
                    }
                    return true;
                }
            };

            const ScopedTimeoutSuiteTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = allocator;
                    _ = args;
                    t.run("timed_branch", TaskRunner.make(ScopedTimedBranchTask.run, null));
                    t.run("plain_branch", TaskRunner.make(ScopedPlainBranchTask.run, null));
                    return t.wait();
                }
            };

            const Helper = struct {
                fn makeRunner(comptime run_fn: anytype, memory_limit: ?usize) TestRunnerHandle {
                    const Runner = struct {
                        memory_limit: ?usize,

                        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                            _ = self;
                            _ = allocator;
                        }

                        pub fn run(self: *@This(), t: *Self, allocator: stdz.mem.Allocator) bool {
                            _ = self;
                            var arg_byte: u8 = 0;
                            return run_fn(t, allocator, @ptrCast(&arg_byte));
                        }

                        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                            _ = allocator;
                            std.testing.allocator.destroy(self);
                        }
                    };

                    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
                    runner.* = .{ .memory_limit = memory_limit };
                    return TestRunnerHandle.make(Runner).new(runner);
                }

                fn appendNormalizedLine(bytes: *std.ArrayList(u8), line: []const u8) !void {
                    var plain_line = std.ArrayList(u8).empty;
                    defer plain_line.deinit(std.testing.allocator);

                    var i: usize = 0;
                    while (i < line.len) {
                        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
                            i += 2;
                            while (i < line.len and line[i] != 'm') : (i += 1) {}
                            if (i < line.len) i += 1;
                            continue;
                        }
                        try plain_line.append(std.testing.allocator, line[i]);
                        i += 1;
                    }

                    const plain = plain_line.items;
                    var compact_line = std.ArrayList(u8).empty;
                    defer compact_line.deinit(std.testing.allocator);
                    const normalized_plain = blk: {
                        if (std.mem.startsWith(u8, plain, ">>> ") or
                            std.mem.startsWith(u8, plain, "<<< ") or
                            std.mem.startsWith(u8, plain, "!!! "))
                        {
                            const prefix = plain[0..4];
                            const rest = plain[4..];
                            const split_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse break :blk plain;
                            const label = rest[0..split_idx];
                            const suffix = std.mem.trimLeft(u8, rest[split_idx..], " ");
                            try compact_line.appendSlice(std.testing.allocator, prefix);
                            try compact_line.appendSlice(std.testing.allocator, label);
                            try compact_line.append(std.testing.allocator, ' ');
                            try compact_line.appendSlice(std.testing.allocator, suffix);
                            break :blk compact_line.items;
                        }
                        break :blk plain;
                    };
                    const event_idx = std.mem.indexOf(u8, normalized_plain, " done at ") orelse
                        std.mem.indexOf(u8, normalized_plain, " failed at ");
                    if (event_idx) |idx| {
                        const prefix = std.mem.trimRight(u8, normalized_plain[0..idx], " ");
                        const suffix = normalized_plain[idx + 1 ..];
                        if (std.mem.indexOf(u8, suffix, "ms, ")) |ms_idx| {
                            try bytes.appendSlice(std.testing.allocator, prefix);
                            try bytes.append(std.testing.allocator, ' ');
                            try bytes.appendSlice(std.testing.allocator, suffix[0 .. ms_idx + 4]);
                            try bytes.appendSlice(std.testing.allocator, "<mem>");
                            return;
                        }
                        try bytes.appendSlice(std.testing.allocator, prefix);
                        try bytes.append(std.testing.allocator, ' ');
                        try bytes.appendSlice(std.testing.allocator, suffix);
                        return;
                    }
                    try bytes.appendSlice(std.testing.allocator, normalized_plain);
                }

                fn normalizedLog() ![]u8 {
                    const actual_log = try Support.joinedLog(std.testing.allocator);
                    defer std.testing.allocator.free(actual_log);

                    var normalized = std.ArrayList(u8).empty;
                    errdefer normalized.deinit(std.testing.allocator);

                    var lines = std.mem.splitScalar(u8, actual_log, '\n');
                    var first = true;
                    while (lines.next()) |line| {
                        if (!first) try normalized.append(std.testing.allocator, '\n');
                        try appendNormalizedLine(&normalized, line);
                        first = false;
                    }
                    return normalized.toOwnedSlice(std.testing.allocator);
                }

                fn expectLog(expected_log: []const u8) !void {
                    const actual_log = try normalizedLog();
                    defer std.testing.allocator.free(actual_log);
                    try std.testing.expectEqualStrings(expected_log, actual_log);
                }
            };

            Support.reset();
            defer Support.reset();

            {
                var root = new(TestLib, .test_run);
                root.timeout(0);
                root.run("immediate", TaskRunner.make(ImmediateTimeoutTask.run, null));
                try std.testing.expect(!root.wait());
                root.deinit();

                const expected_log =
                    \\>>> /immediate start at 0.0s
                    \\!!! /immediate immediate timeout
                    \\!!! /immediate failed at 0.0s, 0ms, <mem>
                    \\!!! summary failed at 0.0s, 0ms, <mem>
                ;

                try Helper.expectLog(expected_log);
            }

            Support.reset();

            {
                var root = new(TestLib, .test_run);
                root.timeout(suite_timeout_ns);
                root.timeout(300 * TestLib.time.ns_per_ms);
                root.run("suite", TaskRunner.make(ComplexTimeoutSuiteTask.run, null));
                try std.testing.expect(!root.wait());
                root.deinit();

                const expected_log =
                    \\>>> /suite start at 0.0s
                    \\>>> /suite/nested start at 0.0s
                    \\>>> /suite/nested/leaf_fast start at 0.0s
                    \\<<< /suite/nested/leaf_fast done at 0.0s, 10ms, <mem>
                    \\>>> /suite/nested/leaf_slow start at 0.0s
                    \\!!! /suite/nested/leaf_slow leaf timeout
                    \\!!! /suite/nested/leaf_slow failed at 0.0s, 70ms, <mem>
                    \\!!! /suite/nested failed at 0.0s, 80ms, <mem>
                    \\>>> /suite/fast start at 0.0s
                    \\>>> /suite/slow start at 0.0s
                    \\<<< /suite/fast done at 0.0s, 10ms, <mem>
                    \\!!! /suite/slow parallel timeout
                    \\!!! /suite/slow failed at 0.1s, 70ms, <mem>
                    \\!!! /suite failed at 0.0s, 80ms, <mem>
                    \\!!! summary failed at 0.0s, 80ms, <mem>
                ;

                try Helper.expectLog(expected_log);
            }

            Support.reset();

            {
                var root = new(TestLib, .test_run);
                root.run("scoped", TaskRunner.make(ScopedTimeoutSuiteTask.run, null));
                try std.testing.expect(!root.wait());
                root.deinit();

                const expected_log =
                    \\>>> /scoped start at 0.0s
                    \\>>> /scoped/timed_branch start at 0.0s
                    \\>>> /scoped/timed_branch/timed_leaf start at 0.0s
                    \\!!! /scoped/timed_branch/timed_leaf branch timeout
                    \\!!! /scoped/timed_branch/timed_leaf failed at 0.0s, 50ms, <mem>
                    \\!!! /scoped/timed_branch failed at 0.0s, 50ms, <mem>
                    \\>>> /scoped/plain_branch start at 0.0s
                    \\<<< /scoped/plain_branch done at 0.0s, 10ms, <mem>
                    \\!!! /scoped failed at 0.0s, 50ms, <mem>
                    \\!!! summary failed at 0.0s, 50ms, <mem>
                ;

                try Helper.expectLog(expected_log);
            }
        }
        fn testMemoryLimit() !void {
            const std = @import("std");
            const stdz = @import("stdz");

            const Support = struct {
                var entries: std.ArrayListUnmanaged([]u8) = .{};
                var mutex: std.Thread.Mutex = .{};
                var now_ns = std.atomic.Value(u64).init(0);

                fn reset() void {
                    mutex.lock();
                    defer mutex.unlock();
                    for (entries.items) |entry| {
                        std.testing.allocator.free(entry);
                    }
                    entries.deinit(std.testing.allocator);
                    entries = .{};
                    now_ns.store(0, .release);
                }

                fn append(comptime format: []const u8, args: anytype) void {
                    const message = std.fmt.allocPrint(std.testing.allocator, format, args) catch @panic("OOM");
                    mutex.lock();
                    defer mutex.unlock();
                    entries.append(std.testing.allocator, message) catch @panic("OOM");
                }

                fn timestampNs() u64 {
                    return now_ns.load(.acquire);
                }

                fn advance(ns: u64) void {
                    _ = now_ns.fetchAdd(ns, .acq_rel);
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

            const TestThread = struct {
                pub const SpawnConfig = std.Thread.SpawnConfig;
                pub const Mutex = std.Thread.Mutex;
                pub const RwLock = std.Thread.RwLock;
                const ThreadSelf = @This();
                pub const Condition = struct {
                    inner: std.Thread.Condition = .{},

                    pub fn wait(self: *Condition, mutex: *Mutex) void {
                        self.inner.wait(mutex);
                    }

                    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
                        self.inner.timedWait(mutex, timeout_ns) catch return error.Timeout;
                    }

                    pub fn signal(self: *Condition) void {
                        self.inner.signal();
                    }

                    pub fn broadcast(self: *Condition) void {
                        self.inner.broadcast();
                    }
                };

                inner: std.Thread,

                pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) !ThreadSelf {
                    return .{
                        .inner = try std.Thread.spawn(config, f, args),
                    };
                }

                pub fn join(self: ThreadSelf) void {
                    self.inner.join();
                }

                pub fn detach(self: ThreadSelf) void {
                    self.inner.detach();
                }

                pub fn sleep(ns: u64) void {
                    Support.advance(ns);
                }
            };

            const TestLib = struct {
                pub const mem = stdz.mem;
                pub const fmt = stdz.fmt;
                pub const Thread = TestThread;
                pub const log = CapturingLog;
                pub fn ArrayList(comptime Elem: type) type {
                    return std.ArrayList(Elem);
                }
                pub const testing = struct {
                    pub const allocator = std.testing.allocator;
                };
                pub const time = struct {
                    pub const ns_per_ms = std.time.ns_per_ms;
                    pub const Instant = std.time.Instant;

                    pub fn nanoTimestamp() i128 {
                        return Support.timestampNs();
                    }

                    pub fn milliTimestamp() i64 {
                        return @intCast(@divFloor(Support.timestampNs(), std.time.ns_per_ms));
                    }
                };
            };

            const TaskRunner = struct {
                fn make(comptime run_fn: anytype, memory_limit: ?usize) TestRunnerHandle {
                    const Runner = struct {
                        memory_limit: ?usize,

                        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                            _ = self;
                            _ = allocator;
                        }

                        pub fn run(self: *@This(), t: *Self, allocator: stdz.mem.Allocator) bool {
                            _ = self;
                            var arg_byte: u8 = 0;
                            return run_fn(t, allocator, @ptrCast(&arg_byte));
                        }

                        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                            _ = allocator;
                            std.testing.allocator.destroy(self);
                        }
                    };

                    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
                    runner.* = .{ .memory_limit = memory_limit };
                    return TestRunnerHandle.make(Runner).new(runner);
                }
            };

            const MemoryLimitFailTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = args;
                    const bytes = allocator.alloc(u8, 64) catch {
                        t.logError("memory limit hit");
                        return false;
                    };
                    defer allocator.free(bytes);
                    return true;
                }
            };

            const MemoryLimitOkTask = struct {
                fn run(t: *Self, allocator: stdz_mod.mem.Allocator, args: *anyopaque) bool {
                    _ = t;
                    _ = args;
                    const bytes = allocator.alloc(u8, 16) catch return false;
                    defer allocator.free(bytes);
                    @memset(bytes, 0xAB);
                    return true;
                }
            };

            const Helper = struct {
                fn makeRunner(comptime run_fn: anytype, memory_limit: ?usize) TestRunnerHandle {
                    const Runner = struct {
                        memory_limit: ?usize,

                        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                            _ = self;
                            _ = allocator;
                        }

                        pub fn run(self: *@This(), t: *Self, allocator: stdz.mem.Allocator) bool {
                            _ = self;
                            var arg_byte: u8 = 0;
                            return run_fn(t, allocator, @ptrCast(&arg_byte));
                        }

                        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                            _ = allocator;
                            std.testing.allocator.destroy(self);
                        }
                    };

                    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
                    runner.* = .{ .memory_limit = memory_limit };
                    return TestRunnerHandle.make(Runner).new(runner);
                }

                fn appendNormalizedLine(bytes: *std.ArrayList(u8), line: []const u8) !void {
                    var plain_line = std.ArrayList(u8).empty;
                    defer plain_line.deinit(std.testing.allocator);

                    var i: usize = 0;
                    while (i < line.len) {
                        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
                            i += 2;
                            while (i < line.len and line[i] != 'm') : (i += 1) {}
                            if (i < line.len) i += 1;
                            continue;
                        }
                        try plain_line.append(std.testing.allocator, line[i]);
                        i += 1;
                    }

                    const plain = plain_line.items;
                    var compact_line = std.ArrayList(u8).empty;
                    defer compact_line.deinit(std.testing.allocator);
                    const normalized_plain = blk: {
                        if (std.mem.startsWith(u8, plain, ">>> ") or
                            std.mem.startsWith(u8, plain, "<<< ") or
                            std.mem.startsWith(u8, plain, "!!! "))
                        {
                            const prefix = plain[0..4];
                            const rest = plain[4..];
                            const split_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse break :blk plain;
                            const label = rest[0..split_idx];
                            const suffix = std.mem.trimLeft(u8, rest[split_idx..], " ");
                            try compact_line.appendSlice(std.testing.allocator, prefix);
                            try compact_line.appendSlice(std.testing.allocator, label);
                            try compact_line.append(std.testing.allocator, ' ');
                            try compact_line.appendSlice(std.testing.allocator, suffix);
                            break :blk compact_line.items;
                        }
                        break :blk plain;
                    };
                    const event_idx = std.mem.indexOf(u8, normalized_plain, " done at ") orelse
                        std.mem.indexOf(u8, normalized_plain, " failed at ");
                    if (event_idx) |idx| {
                        const prefix = std.mem.trimRight(u8, normalized_plain[0..idx], " ");
                        const suffix = normalized_plain[idx + 1 ..];
                        if (std.mem.indexOf(u8, suffix, "ms, ")) |ms_idx| {
                            try bytes.appendSlice(std.testing.allocator, prefix);
                            try bytes.append(std.testing.allocator, ' ');
                            try bytes.appendSlice(std.testing.allocator, suffix[0 .. ms_idx + 4]);
                            try bytes.appendSlice(std.testing.allocator, "<mem>");
                            return;
                        }
                        try bytes.appendSlice(std.testing.allocator, prefix);
                        try bytes.append(std.testing.allocator, ' ');
                        try bytes.appendSlice(std.testing.allocator, suffix);
                        return;
                    }
                    try bytes.appendSlice(std.testing.allocator, normalized_plain);
                }

                fn normalizedLog() ![]u8 {
                    const actual_log = try Support.joinedLog(std.testing.allocator);
                    defer std.testing.allocator.free(actual_log);

                    var normalized = std.ArrayList(u8).empty;
                    errdefer normalized.deinit(std.testing.allocator);

                    var lines = std.mem.splitScalar(u8, actual_log, '\n');
                    var first = true;
                    while (lines.next()) |line| {
                        if (!first) try normalized.append(std.testing.allocator, '\n');
                        try appendNormalizedLine(&normalized, line);
                        first = false;
                    }
                    return normalized.toOwnedSlice(std.testing.allocator);
                }

                fn expectLog(expected_log: []const u8) !void {
                    const actual_log = try normalizedLog();
                    defer std.testing.allocator.free(actual_log);
                    try std.testing.expectEqualStrings(expected_log, actual_log);
                }
            };

            Support.reset();
            defer Support.reset();

            {
                var root = new(TestLib, .test_run);
                root.run("limited", TaskRunner.make(MemoryLimitFailTask.run, 32));
                try std.testing.expect(!root.wait());
                root.deinit();

                const expected_log =
                    \\>>> /limited start at 0.0s
                    \\!!! /limited memory limit hit
                    \\!!! /limited failed at 0.0s, 0ms, <mem>
                    \\!!! summary failed at 0.0s, 0ms, <mem>
                ;
                try Helper.expectLog(expected_log);
            }

            Support.reset();

            {
                var root = new(TestLib, .test_run);
                root.run("within_limit", TaskRunner.make(MemoryLimitOkTask.run, 32));
                try std.testing.expect(root.wait());
                root.deinit();

                const expected_log =
                    \\>>> /within_limit start at 0.0s
                    \\<<< /within_limit done at 0.0s, 0ms, <mem>
                    \\<<< summary done at 0.0s, 0ms, <mem>
                ;

                try Helper.expectLog(expected_log);
            }
        }
        fn testPeakMemoryUsesTreePeak() !void {
            const std = @import("std");
            const stdz = @import("stdz");

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

            const TestThread = struct {
                pub const SpawnConfig = std.Thread.SpawnConfig;
                pub const Mutex = std.Thread.Mutex;
                pub const RwLock = std.Thread.RwLock;
                const ThreadSelf = @This();

                pub const Condition = struct {
                    inner: std.Thread.Condition = .{},

                    pub fn wait(self: *Condition, mutex: *Mutex) void {
                        self.inner.wait(mutex);
                    }

                    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
                        self.inner.timedWait(mutex, timeout_ns) catch return error.Timeout;
                    }

                    pub fn signal(self: *Condition) void {
                        self.inner.signal();
                    }

                    pub fn broadcast(self: *Condition) void {
                        self.inner.broadcast();
                    }
                };

                pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) !ThreadSelf {
                    _ = config;
                    @call(.auto, f, args);
                    return .{};
                }

                pub fn join(self: ThreadSelf) void {
                    _ = self;
                }

                pub fn detach(self: ThreadSelf) void {
                    _ = self;
                }

                pub fn sleep(ns: u64) void {
                    _ = ns;
                }
            };

            const TestLib = struct {
                pub const mem = stdz.mem;
                pub const fmt = stdz.fmt;
                pub const Thread = TestThread;
                pub const log = CapturingLog;

                pub fn ArrayList(comptime Elem: type) type {
                    return std.ArrayList(Elem);
                }

                pub const testing = struct {
                    pub const allocator = std.testing.allocator;
                };

                pub const time = struct {
                    pub const ns_per_ms = std.time.ns_per_ms;
                    pub const Instant = std.time.Instant;

                    pub fn nanoTimestamp() i128 {
                        return 0;
                    }

                    pub fn milliTimestamp() i64 {
                        return 0;
                    }
                };
            };

            const TaskRunner = struct {
                fn make(comptime run_fn: anytype) TestRunnerHandle {
                    const Runner = struct {
                        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                            _ = self;
                            _ = allocator;
                        }

                        pub fn run(self: *@This(), t: *Self, allocator: stdz.mem.Allocator) bool {
                            _ = self;
                            return run_fn(t, allocator);
                        }

                        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                            _ = allocator;
                            std.testing.allocator.destroy(self);
                        }
                    };

                    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
                    runner.* = .{};
                    return TestRunnerHandle.make(Runner).new(runner);
                }
            };

            const LeafTask = struct {
                fn run(t: *Self, allocator: stdz.mem.Allocator) bool {
                    _ = t;
                    const bytes = allocator.alloc(u8, 384) catch return false;
                    defer allocator.free(bytes);
                    return true;
                }
            };

            const SuiteTask = struct {
                fn run(t: *Self, allocator: stdz.mem.Allocator) bool {
                    _ = allocator;
                    t.run("child_a", TaskRunner.make(LeafTask.run));
                    t.run("child_b", TaskRunner.make(LeafTask.run));
                    return t.wait();
                }
            };

            const Helper = struct {
                fn plainLog() ![]u8 {
                    const actual_log = try Support.joinedLog(std.testing.allocator);
                    defer std.testing.allocator.free(actual_log);

                    var plain = std.ArrayList(u8).empty;
                    errdefer plain.deinit(std.testing.allocator);

                    var i: usize = 0;
                    while (i < actual_log.len) {
                        if (actual_log[i] == 0x1b and i + 1 < actual_log.len and actual_log[i + 1] == '[') {
                            i += 2;
                            while (i < actual_log.len and actual_log[i] != 'm') : (i += 1) {}
                            if (i < actual_log.len) i += 1;
                            continue;
                        }
                        try plain.append(std.testing.allocator, actual_log[i]);
                        i += 1;
                    }
                    return plain.toOwnedSlice(std.testing.allocator);
                }

                fn parseMemoryUsage(text: []const u8) !usize {
                    const space_idx = std.mem.lastIndexOfScalar(u8, text, ' ') orelse return error.BadMemoryText;
                    const number_text = text[0..space_idx];
                    const unit_text = text[space_idx + 1 ..];
                    const scale: usize = if (std.mem.eql(u8, unit_text, "B"))
                        1
                    else if (std.mem.eql(u8, unit_text, "KiB"))
                        1024
                    else if (std.mem.eql(u8, unit_text, "MiB"))
                        1024 * 1024
                    else
                        return error.BadMemoryUnit;

                    if (scale == 1) return std.fmt.parseInt(usize, number_text, 10);

                    const dot_idx = std.mem.indexOfScalar(u8, number_text, '.') orelse return error.BadMemoryNumber;
                    const whole = try std.fmt.parseInt(usize, number_text[0..dot_idx], 10);
                    const frac_text = number_text[dot_idx + 1 ..];
                    const frac = try std.fmt.parseInt(usize, frac_text, 10);
                    return whole * scale + (frac * scale) / 1000;
                }

                fn peakForLabel(log: []const u8, label: []const u8) !usize {
                    var lines = std.mem.splitScalar(u8, log, '\n');
                    while (lines.next()) |line| {
                        if (!std.mem.startsWith(u8, line, "<<< ")) continue;
                        const rest = line[4..];
                        if (!std.mem.startsWith(u8, rest, label)) continue;
                        if (std.mem.indexOf(u8, rest[label.len..], "done at ") == null) continue;
                        const mem_idx = std.mem.lastIndexOf(u8, line, ", ") orelse return error.BadPeakLine;
                        return parseMemoryUsage(line[mem_idx + 2 ..]);
                    }
                    return error.MissingPeakLine;
                }
            };

            Support.reset();
            defer Support.reset();

            var root = new(TestLib, .test_run);
            root.run("suite", TaskRunner.make(SuiteTask.run));
            try std.testing.expect(root.wait());
            root.deinit();

            const log = try Helper.plainLog();
            defer std.testing.allocator.free(log);

            const suite_peak = try Helper.peakForLabel(log, "/suite");
            const child_a_peak = try Helper.peakForLabel(log, "/suite/child_a");
            const child_b_peak = try Helper.peakForLabel(log, "/suite/child_b");

            try std.testing.expect(suite_peak + 64 < child_a_peak + child_b_peak);
        }
        fn testSubtestStartFailureCleanup() !void {
            const std = @import("std");
            const stdz = @import("stdz");

            const FailNthAllocator = struct {
                backing: stdz.mem.Allocator,
                alloc_index: usize = 0,
                fail_at_alloc_index: ?usize = null,

                fn allocator(self: *@This()) stdz.mem.Allocator {
                    return .{
                        .ptr = self,
                        .vtable = &vtable,
                    };
                }

                fn alloc(ptr: *anyopaque, len: usize, alignment: stdz.mem.Alignment, ret_addr: usize) ?[*]u8 {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    defer self.alloc_index += 1;
                    if (self.fail_at_alloc_index) |fail_at| {
                        if (self.alloc_index == fail_at) return null;
                    }
                    return self.backing.rawAlloc(len, alignment, ret_addr);
                }

                fn resize(ptr: *anyopaque, memory: []u8, alignment: stdz.mem.Alignment, new_len: usize, ret_addr: usize) bool {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    return self.backing.rawResize(memory, alignment, new_len, ret_addr);
                }

                fn remap(ptr: *anyopaque, memory: []u8, alignment: stdz.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
                }

                fn free(ptr: *anyopaque, memory: []u8, alignment: stdz.mem.Alignment, ret_addr: usize) void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    self.backing.rawFree(memory, alignment, ret_addr);
                }

                const vtable: stdz.mem.Allocator.VTable = .{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                };
            };

            const Support = struct {
                var entries: std.ArrayListUnmanaged([]u8) = .{};
                var mutex: std.Thread.Mutex = .{};
                var now_ns = std.atomic.Value(u64).init(0);
                var fail_spawn = false;
                var runner_run_hits: usize = 0;
                var runner_deinit_hits: usize = 0;

                fn reset() void {
                    mutex.lock();
                    defer mutex.unlock();
                    for (entries.items) |entry| {
                        std.testing.allocator.free(entry);
                    }
                    entries.deinit(std.testing.allocator);
                    entries = .{};
                    now_ns.store(0, .release);
                    fail_spawn = false;
                    runner_run_hits = 0;
                    runner_deinit_hits = 0;
                }

                fn append(comptime format: []const u8, args: anytype) void {
                    const message = std.fmt.allocPrint(std.testing.allocator, format, args) catch @panic("OOM");
                    mutex.lock();
                    defer mutex.unlock();
                    entries.append(std.testing.allocator, message) catch @panic("OOM");
                }

                fn timestampNs() u64 {
                    return now_ns.load(.acquire);
                }

                fn advance(ns: u64) void {
                    _ = now_ns.fetchAdd(ns, .acq_rel);
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

            const TestThread = struct {
                pub const SpawnConfig = std.Thread.SpawnConfig;
                pub const Mutex = std.Thread.Mutex;
                pub const RwLock = std.Thread.RwLock;
                const ThreadSelf = @This();

                pub const Condition = struct {
                    inner: std.Thread.Condition = .{},

                    pub fn wait(self: *Condition, mutex: *Mutex) void {
                        self.inner.wait(mutex);
                    }

                    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
                        self.inner.timedWait(mutex, timeout_ns) catch return error.Timeout;
                    }

                    pub fn signal(self: *Condition) void {
                        self.inner.signal();
                    }

                    pub fn broadcast(self: *Condition) void {
                        self.inner.broadcast();
                    }
                };

                pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) error{ThreadQuotaExceeded}!ThreadSelf {
                    _ = config;
                    if (Support.fail_spawn) return error.ThreadQuotaExceeded;
                    @call(.auto, f, args);
                    return .{};
                }

                pub fn join(self: ThreadSelf) void {
                    _ = self;
                }

                pub fn detach(self: ThreadSelf) void {
                    _ = self;
                }

                pub fn sleep(ns: u64) void {
                    Support.advance(ns);
                }
            };

            const TestLib = struct {
                pub const mem = stdz.mem;
                pub const fmt = stdz.fmt;
                pub const Thread = TestThread;
                pub const log = CapturingLog;

                pub fn ArrayList(comptime Elem: type) type {
                    return std.ArrayList(Elem);
                }

                pub const testing = struct {
                    pub var allocator: stdz.mem.Allocator = undefined;
                };

                pub const time = struct {
                    pub const ns_per_ms = std.time.ns_per_ms;
                    pub const Instant = std.time.Instant;

                    pub fn nanoTimestamp() i128 {
                        return Support.timestampNs();
                    }

                    pub fn milliTimestamp() i64 {
                        return @intCast(@divFloor(Support.timestampNs(), std.time.ns_per_ms));
                    }
                };
            };

            const Helper = struct {
                fn makeTrackedRunner() TestRunnerHandle {
                    const Runner = struct {
                        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
                            _ = self;
                            _ = allocator;
                        }

                        pub fn run(self: *@This(), t: *Self, allocator: stdz.mem.Allocator) bool {
                            _ = self;
                            _ = t;
                            _ = allocator;
                            Support.runner_run_hits += 1;
                            return true;
                        }

                        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
                            _ = allocator;
                            Support.runner_deinit_hits += 1;
                            std.testing.allocator.destroy(self);
                        }
                    };

                    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
                    runner.* = .{};
                    return TestRunnerHandle.make(Runner).new(runner);
                }

                fn normalizedLogContains(needle: []const u8) !bool {
                    const actual_log = try Support.joinedLog(std.testing.allocator);
                    defer std.testing.allocator.free(actual_log);

                    var plain = std.ArrayList(u8).empty;
                    defer plain.deinit(std.testing.allocator);

                    var i: usize = 0;
                    while (i < actual_log.len) {
                        if (actual_log[i] == 0x1b and i + 1 < actual_log.len and actual_log[i + 1] == '[') {
                            i += 2;
                            while (i < actual_log.len and actual_log[i] != 'm') : (i += 1) {}
                            if (i < actual_log.len) i += 1;
                            continue;
                        }
                        try plain.append(std.testing.allocator, actual_log[i]);
                        i += 1;
                    }

                    return std.mem.indexOf(u8, plain.items, needle) != null;
                }
            };

            Support.reset();
            defer Support.reset();

            {
                var found_pending_alloc_failure = false;

                for (0..32) |fail_offset| {
                    Support.reset();

                    var allocator_state = FailNthAllocator{
                        .backing = std.testing.allocator,
                    };
                    TestLib.testing.allocator = allocator_state.allocator();

                    var root = new(TestLib, .test_run);
                    allocator_state.fail_at_alloc_index = allocator_state.alloc_index + fail_offset;

                    root.run("child", Helper.makeTrackedRunner());
                    const ok = root.wait();
                    root.deinit();

                    if (try Helper.normalizedLogContains("subtest state alloc failed")) {
                        try std.testing.expect(!ok);
                        try std.testing.expectEqual(@as(usize, 0), Support.runner_run_hits);
                        try std.testing.expectEqual(@as(usize, 1), Support.runner_deinit_hits);
                        found_pending_alloc_failure = true;
                        break;
                    }
                }

                try std.testing.expect(found_pending_alloc_failure);
            }

            Support.reset();
            Support.fail_spawn = true;
            TestLib.testing.allocator = std.testing.allocator;

            {
                var root = new(TestLib, .test_run);
                root.run("child", Helper.makeTrackedRunner());
                try std.testing.expect(!root.wait());
                root.deinit();
            }

            try std.testing.expect(try Helper.normalizedLogContains("subtest spawn failed"));
            try std.testing.expectEqual(@as(usize, 0), Support.runner_run_hits);
            try std.testing.expectEqual(@as(usize, 1), Support.runner_deinit_hits);
        }

        fn testBeforeRunHook() !void {
            const std = @import("std");
            const TR = @import("TestRunner.zig");

            const HookCtx = struct {
                var hits: usize = 0;
                var saw_memory_limit: ?usize = null;

                fn beforeRun(child: *Self, runner: *TR) void {
                    _ = child;
                    hits += 1;
                    saw_memory_limit = runner.memory_limit;
                    runner.memory_limit = 77;
                }
            };

            const Runner = struct {
                pub fn init(self: *@This(), allocator: stdz_mod.mem.Allocator) !void {
                    _ = self;
                    _ = allocator;
                }

                pub fn run(self: *@This(), t: *Self, allocator: stdz_mod.mem.Allocator) bool {
                    _ = self;
                    _ = t;
                    _ = allocator;
                    return true;
                }

                pub fn deinit(self: *@This(), allocator: stdz_mod.mem.Allocator) void {
                    _ = self;
                    _ = allocator;
                }
            };

            HookCtx.hits = 0;
            HookCtx.saw_memory_limit = null;

            var root = new(std, .std);
            defer root.deinit();
            root.setTestHook(.{ .beforeRun = HookCtx.beforeRun });

            const Holder = struct {
                var runner: Runner = .{};
            };
            const child_limit: ?usize = 9;
            var runner = TR.make(Runner).new(&Holder.runner);
            runner.memory_limit = child_limit;

            root.run("hooked", runner);
            try std.testing.expect(root.wait());
            try std.testing.expectEqual(@as(usize, 1), HookCtx.hits);
            try std.testing.expectEqual(child_limit, HookCtx.saw_memory_limit);
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *Self, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testFormatMemoryUsage() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testContextCancelLogs() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testTimeout() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testMemoryLimit() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPeakMemoryUsesTreePeak() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testSubtestStartFailureCleanup() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testBeforeRunHook() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
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
    return TestRunnerHandle.make(Runner).new(&Holder.runner);
}
