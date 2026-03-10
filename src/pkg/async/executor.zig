const std = @import("std");
const runtime = struct {
    pub const sync = @import("../../runtime/sync.zig");
    pub const std = @import("../../runtime/std.zig");
};
const cancellation = @import("cancellation.zig");

pub const TaskFn = *const fn (?*anyopaque) anyerror!void;

pub const Task = struct {
    func: TaskFn,
    ctx: ?*anyopaque,
    cancel_token: ?cancellation.Token = null,
};

/// Task executor parameterized on an explicit mutex primitive.
/// Uses `Mutex` for thread-safe submit / run.
/// Tasks are executed outside the lock to avoid deadlocks on re-entrant submit.
pub fn Executor(comptime Mutex: type) type {
    comptime _ = runtime.sync.Mutex(Mutex);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mutex: Mutex,
        queue: []Task,
        queue_head: usize = 0,
        queue_len: usize = 0,
        queue_cap: usize = 0,
        completed: usize = 0,
        failed: usize = 0,
        cancelled: usize = 0,
        last_errors: [max_error_log]anyerror = undefined,
        error_count: usize = 0,

        const max_error_log = 32;

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .mutex = Mutex.init(),
                .queue = &.{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.deinit();
            if (self.queue_cap > 0) {
                self.allocator.free(self.queue[0..self.queue_cap]);
            }
            self.* = undefined;
        }

        pub fn submit(self: *Self, task: Task) std.mem.Allocator.Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.ensureCapacity();
            const idx = (self.queue_head + self.queue_len) % self.queue_cap;
            self.queue[idx] = task;
            self.queue_len += 1;
        }

        pub fn pending(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.queue_len;
        }

        pub fn runNext(self: *Self) !bool {
            const task = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.queue_len == 0) return false;
                const t = self.queue[self.queue_head];
                self.queue_head = (self.queue_head + 1) % self.queue_cap;
                self.queue_len -= 1;
                break :blk t;
            };

            if (task.cancel_token) |tok| {
                if (tok.isCancelled()) {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.cancelled += 1;
                    return true;
                }
            }

            task.func(task.ctx) catch |err| {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.failed += 1;
                self.recordError(err);
                return true;
            };

            self.mutex.lock();
            defer self.mutex.unlock();
            self.completed += 1;
            return true;
        }

        pub fn runAll(self: *Self) !void {
            while (try self.runNext()) {}
        }

        pub fn getErrors(self: *Self) []const anyerror {
            self.mutex.lock();
            defer self.mutex.unlock();
            const count_val = @min(self.error_count, max_error_log);
            return self.last_errors[0..count_val];
        }

        pub fn stats(self: *Self) Stats {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{
                .completed = self.completed,
                .failed = self.failed,
                .cancelled = self.cancelled,
                .pending = self.queue_len,
            };
        }

        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue_head = 0;
            self.queue_len = 0;
            self.completed = 0;
            self.failed = 0;
            self.cancelled = 0;
            self.error_count = 0;
        }

        fn recordError(self: *Self, err: anyerror) void {
            if (self.error_count < max_error_log) {
                self.last_errors[self.error_count] = err;
            }
            self.error_count += 1;
        }

        fn ensureCapacity(self: *Self) std.mem.Allocator.Error!void {
            if (self.queue_len < self.queue_cap) return;

            const new_cap = if (self.queue_cap == 0) 16 else self.queue_cap * 2;
            const new_buf = try self.allocator.alloc(Task, new_cap);

            if (self.queue_cap > 0) {
                var i: usize = 0;
                while (i < self.queue_len) : (i += 1) {
                    new_buf[i] = self.queue[(self.queue_head + i) % self.queue_cap];
                }
                self.allocator.free(self.queue[0..self.queue_cap]);
            }

            self.queue = new_buf.ptr[0..new_buf.len];
            self.queue_head = 0;
            self.queue_cap = new_cap;
        }

        pub const Stats = struct {
            completed: usize,
            failed: usize,
            cancelled: usize,
            pending: usize,
        };
    };
}

test "executor runs 200 tasks to completion" {
    const Ctx = struct {
        value: usize = 0,
    };

    const incTask = struct {
        fn run(raw: ?*anyopaque) !void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return error.MissingContext));
            ctx.value += 1;
        }
    }.run;

    var ctx = Ctx{};
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try exec.submit(.{ .func = incTask, .ctx = &ctx });
    }

    try exec.runAll();
    const s = exec.stats();
    try std.testing.expectEqual(@as(usize, 200), ctx.value);
    try std.testing.expectEqual(@as(usize, 200), s.completed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    try std.testing.expectEqual(@as(usize, 0), s.cancelled);
}

test "executor records errors without stopping loop" {
    const Ctx = struct {
        fail_every: usize,
        seen: usize = 0,
    };

    const maybeFail = struct {
        fn run(raw: ?*anyopaque) !void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return error.MissingContext));
            ctx.seen += 1;
            if (ctx.seen % ctx.fail_every == 0) return error.InjectFailure;
        }
    }.run;

    var ctx = Ctx{ .fail_every = 10 };
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try exec.submit(.{ .func = maybeFail, .ctx = &ctx });
    }

    try exec.runAll();
    const s = exec.stats();
    try std.testing.expectEqual(@as(usize, 50), ctx.seen);
    try std.testing.expectEqual(@as(usize, 45), s.completed);
    try std.testing.expectEqual(@as(usize, 5), s.failed);

    const errors = exec.getErrors();
    try std.testing.expectEqual(@as(usize, 5), errors.len);
    for (errors) |err| {
        try std.testing.expectEqual(error.InjectFailure, err);
    }
}

test "executor respects cancel token" {
    const noop = struct {
        fn run(_: ?*anyopaque) !void {}
    }.run;

    var cancel_src = cancellation.Source{};
    const tok = cancel_src.token();

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = noop, .ctx = null });
    try exec.submit(.{ .func = noop, .ctx = null, .cancel_token = tok });
    try exec.submit(.{ .func = noop, .ctx = null, .cancel_token = tok });
    try exec.submit(.{ .func = noop, .ctx = null });

    _ = cancel_src.cancel();

    try exec.runAll();
    const s = exec.stats();
    try std.testing.expectEqual(@as(usize, 2), s.completed);
    try std.testing.expectEqual(@as(usize, 2), s.cancelled);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
}

test "executor ring buffer wraps correctly" {
    const Ctx = struct { count: usize = 0 };
    const inc = struct {
        fn run(raw: ?*anyopaque) !void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return));
            ctx.count += 1;
        }
    }.run;

    var ctx = Ctx{};
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try exec.submit(.{ .func = inc, .ctx = &ctx });
        _ = try exec.runNext();
    }

    try std.testing.expectEqual(@as(usize, 100), ctx.count);
    try std.testing.expectEqual(@as(usize, 0), exec.pending());
}

test "executor empty runAll does nothing" {
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.runAll();
    const s = exec.stats();
    try std.testing.expectEqual(@as(usize, 0), s.completed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    try std.testing.expectEqual(@as(usize, 0), s.cancelled);
    try std.testing.expectEqual(@as(usize, 0), s.pending);
}

test "executor empty runNext returns false" {
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try std.testing.expect(!try exec.runNext());
}

test "executor stats on fresh instance all zero" {
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    const s = exec.stats();
    try std.testing.expectEqual(@as(usize, 0), s.completed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    try std.testing.expectEqual(@as(usize, 0), s.cancelled);
    try std.testing.expectEqual(@as(usize, 0), s.pending);
}

test "executor getErrors empty on fresh instance" {
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try std.testing.expectEqual(@as(usize, 0), exec.getErrors().len);
}

test "executor reset clears all counters" {
    const noop = struct {
        fn run(_: ?*anyopaque) !void {}
    }.run;

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try exec.submit(.{ .func = noop, .ctx = null });
    }
    try exec.runAll();
    try std.testing.expectEqual(@as(usize, 5), exec.stats().completed);

    exec.reset();
    const s = exec.stats();
    try std.testing.expectEqual(@as(usize, 0), s.completed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    try std.testing.expectEqual(@as(usize, 0), s.cancelled);
    try std.testing.expectEqual(@as(usize, 0), s.pending);
    try std.testing.expectEqual(@as(usize, 0), exec.getErrors().len);
}

test "executor error log caps at 32 entries" {
    const fail = struct {
        fn run(_: ?*anyopaque) !void {
            return error.Boom;
        }
    }.run;

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try exec.submit(.{ .func = fail, .ctx = null });
    }
    try exec.runAll();

    try std.testing.expectEqual(@as(usize, 50), exec.stats().failed);
    try std.testing.expectEqual(@as(usize, 32), exec.getErrors().len);
}

test "executor mixed completed failed cancelled tasks" {
    const noop = struct {
        fn run(_: ?*anyopaque) !void {}
    }.run;
    const fail = struct {
        fn run(_: ?*anyopaque) !void {
            return error.Fail;
        }
    }.run;

    var cancel_src = cancellation.Source{};
    _ = cancel_src.cancel();
    const tok = cancel_src.token();

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = noop, .ctx = null });
    try exec.submit(.{ .func = fail, .ctx = null });
    try exec.submit(.{ .func = noop, .ctx = null, .cancel_token = tok });
    try exec.submit(.{ .func = noop, .ctx = null });
    try exec.submit(.{ .func = fail, .ctx = null });
    try exec.submit(.{ .func = noop, .ctx = null, .cancel_token = tok });

    try exec.runAll();
    const s = exec.stats();
    try std.testing.expectEqual(@as(usize, 2), s.completed);
    try std.testing.expectEqual(@as(usize, 2), s.failed);
    try std.testing.expectEqual(@as(usize, 2), s.cancelled);
    try std.testing.expectEqual(@as(usize, 0), s.pending);
}

test "executor submit single task and run" {
    const Ctx = struct { ran: bool = false };
    const task_fn = struct {
        fn run(raw: ?*anyopaque) !void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return));
            ctx.ran = true;
        }
    }.run;

    var ctx = Ctx{};
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = task_fn, .ctx = &ctx });
    try std.testing.expectEqual(@as(usize, 1), exec.pending());

    _ = try exec.runNext();
    try std.testing.expect(ctx.ran);
    try std.testing.expectEqual(@as(usize, 0), exec.pending());
}

test "executor pending tracks queue depth" {
    const noop = struct {
        fn run(_: ?*anyopaque) !void {}
    }.run;

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try std.testing.expectEqual(@as(usize, 0), exec.pending());

    try exec.submit(.{ .func = noop, .ctx = null });
    try exec.submit(.{ .func = noop, .ctx = null });
    try exec.submit(.{ .func = noop, .ctx = null });
    try std.testing.expectEqual(@as(usize, 3), exec.pending());

    _ = try exec.runNext();
    try std.testing.expectEqual(@as(usize, 2), exec.pending());

    try exec.runAll();
    try std.testing.expectEqual(@as(usize, 0), exec.pending());
}

test "executor cancelled task does not invoke task function" {
    const Ctx = struct { called: usize = 0 };
    const task = struct {
        fn run(raw: ?*anyopaque) !void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return error.MissingContext));
            ctx.called += 1;
        }
    }.run;

    var cancel_src = cancellation.Source{};
    _ = cancel_src.cancel();

    var ctx = Ctx{};
    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = task, .ctx = &ctx, .cancel_token = cancel_src.token() });
    try exec.runAll();

    try std.testing.expectEqual(@as(usize, 0), ctx.called);
    try std.testing.expectEqual(@as(usize, 1), exec.stats().cancelled);
}

test "executor runNext on cancelled task returns true and drains pending" {
    const noop = struct {
        fn run(_: ?*anyopaque) !void {}
    }.run;

    var cancel_src = cancellation.Source{};
    _ = cancel_src.cancel();

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = noop, .ctx = null, .cancel_token = cancel_src.token() });
    try std.testing.expectEqual(@as(usize, 1), exec.pending());

    try std.testing.expect(try exec.runNext());
    try std.testing.expectEqual(@as(usize, 0), exec.pending());
    try std.testing.expectEqual(@as(usize, 1), exec.stats().cancelled);
}

test "executor runNext failure records error entry" {
    const fail = struct {
        fn run(_: ?*anyopaque) !void {
            return error.OneShotFailure;
        }
    }.run;

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = fail, .ctx = null });
    try std.testing.expect(try exec.runNext());

    try std.testing.expectEqual(@as(usize, 1), exec.stats().failed);
    const errs = exec.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqual(error.OneShotFailure, errs[0]);
}

test "executor preserves error order in log" {
    const failA = struct {
        fn run(_: ?*anyopaque) !void {
            return error.FailA;
        }
    }.run;
    const failB = struct {
        fn run(_: ?*anyopaque) !void {
            return error.FailB;
        }
    }.run;
    const failC = struct {
        fn run(_: ?*anyopaque) !void {
            return error.FailC;
        }
    }.run;

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = failA, .ctx = null });
    try exec.submit(.{ .func = failB, .ctx = null });
    try exec.submit(.{ .func = failC, .ctx = null });
    try exec.runAll();

    const errs = exec.getErrors();
    try std.testing.expectEqual(@as(usize, 3), errs.len);
    try std.testing.expectEqual(error.FailA, errs[0]);
    try std.testing.expectEqual(error.FailB, errs[1]);
    try std.testing.expectEqual(error.FailC, errs[2]);
}

test "executor supports reentrant submit from task" {
    const Exec = Executor(runtime.std.Mutex);
    const followup = struct {
        fn run(raw: ?*anyopaque) !void {
            const flag: *bool = @ptrCast(@alignCast(raw orelse return error.MissingContext));
            flag.* = true;
        }
    }.run;

    const Ctx = struct {
        exec: *Exec,
        ran_followup: *bool,
    };
    const first = struct {
        fn run(raw: ?*anyopaque) !void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return error.MissingContext));
            try ctx.exec.submit(.{ .func = followup, .ctx = ctx.ran_followup });
        }
    }.run;

    var ran = false;
    var exec = Exec.init(std.testing.allocator);
    defer exec.deinit();
    var ctx = Ctx{ .exec = &exec, .ran_followup = &ran };

    try exec.submit(.{ .func = first, .ctx = &ctx });
    try exec.runAll();

    try std.testing.expect(ran);
    try std.testing.expectEqual(@as(usize, 2), exec.stats().completed);
}

test "executor reset after failure allows clean reuse" {
    const fail = struct {
        fn run(_: ?*anyopaque) !void {
            return error.ResetMe;
        }
    }.run;
    const noop = struct {
        fn run(_: ?*anyopaque) !void {}
    }.run;

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = fail, .ctx = null });
    try exec.runAll();
    try std.testing.expectEqual(@as(usize, 1), exec.stats().failed);

    exec.reset();
    try exec.submit(.{ .func = noop, .ctx = null });
    try exec.runAll();

    const s = exec.stats();
    try std.testing.expectEqual(@as(usize, 1), s.completed);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    try std.testing.expectEqual(@as(usize, 0), exec.getErrors().len);
}

test "executor processes tasks in FIFO submission order" {
    const Recorder = struct {
        out: [3]u8 = .{ 0, 0, 0 },
        idx: usize = 0,
    };
    const TaskCtx = struct {
        rec: *Recorder,
        val: u8,
    };
    const task = struct {
        fn run(raw: ?*anyopaque) !void {
            const ctx: *TaskCtx = @ptrCast(@alignCast(raw orelse return error.MissingContext));
            ctx.rec.out[ctx.rec.idx] = ctx.val;
            ctx.rec.idx += 1;
        }
    }.run;

    var rec = Recorder{};
    var c1 = TaskCtx{ .rec = &rec, .val = 2 };
    var c2 = TaskCtx{ .rec = &rec, .val = 4 };
    var c3 = TaskCtx{ .rec = &rec, .val = 6 };

    var exec = Executor(runtime.std.Mutex).init(std.testing.allocator);
    defer exec.deinit();
    try exec.submit(.{ .func = task, .ctx = &c1 });
    try exec.submit(.{ .func = task, .ctx = &c2 });
    try exec.submit(.{ .func = task, .ctx = &c3 });
    try exec.runAll();

    try std.testing.expectEqual(@as(usize, 3), rec.idx);
    try std.testing.expectEqual(@as(u8, 2), rec.out[0]);
    try std.testing.expectEqual(@as(u8, 4), rec.out[1]);
    try std.testing.expectEqual(@as(u8, 6), rec.out[2]);
}

test "executor runAll handles finite task chain submission" {
    const Exec = Executor(runtime.std.Mutex);
    const Ctx = struct {
        exec: *Exec,
        remaining: usize,
        ran: usize = 0,
    };
    const chain = struct {
        fn run(raw: ?*anyopaque) !void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return error.MissingContext));
            ctx.ran += 1;
            ctx.remaining -= 1;
            if (ctx.remaining > 0) {
                try ctx.exec.submit(.{ .func = run, .ctx = ctx });
            }
        }
    }.run;

    var exec = Exec.init(std.testing.allocator);
    defer exec.deinit();
    var ctx = Ctx{ .exec = &exec, .remaining = 3 };

    try exec.submit(.{ .func = chain, .ctx = &ctx });
    try exec.runAll();

    try std.testing.expectEqual(@as(usize, 3), ctx.ran);
    try std.testing.expectEqual(@as(usize, 3), exec.stats().completed);
}
