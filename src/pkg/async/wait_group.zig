const std = @import("std");
const runtime = struct {
    pub const sync = @import("../../runtime/sync.zig");
    pub const std = @import("../../runtime/std.zig");
};

pub const WaitGroupError = error{
    Underflow,
};

pub const CallbackFn = *const fn (?*anyopaque) void;

/// Wait group parameterized on explicit sync primitives.
/// Uses `Mutex` and `Condition` for thread-safe blocking `wait()`.
/// Also supports cooperative polling via `isDone()` and completion callbacks.
pub fn WaitGroup(comptime Mutex: type, comptime Cond: type) type {
    comptime {
        _ = runtime.sync.Mutex(Mutex);
        _ = runtime.sync.ConditionWithMutex(Cond, Mutex);
    }

    return struct {
        const Self = @This();

        mutex: Mutex,
        cond: Cond,
        pending: usize = 0,
        on_complete_fn: ?CallbackFn = null,
        on_complete_ctx: ?*anyopaque = null,

        pub fn init() Self {
            return .{
                .mutex = Mutex.init(),
                .cond = Cond.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.cond.deinit();
            self.mutex.deinit();
        }

        pub fn add(self: *Self, n: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pending += n;
        }

        pub fn done(self: *Self) WaitGroupError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.pending == 0) return error.Underflow;
            self.pending -= 1;
            if (self.pending == 0) {
                if (self.on_complete_fn) |func| {
                    func(self.on_complete_ctx);
                }
                self.cond.broadcast();
            }
        }

        /// Blocking wait — returns when pending reaches zero.
        pub fn wait(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.pending > 0) {
                self.cond.wait(&self.mutex);
            }
        }

        pub fn isDone(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.pending == 0;
        }

        pub fn remaining(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.pending;
        }

        pub fn onComplete(self: *Self, func: CallbackFn, ctx: ?*anyopaque) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.on_complete_fn = func;
            self.on_complete_ctx = ctx;
        }

        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pending = 0;
            self.on_complete_fn = null;
            self.on_complete_ctx = null;
        }
    };
}

test "waitgroup basic synchronization add=10 done=10" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(10);
    try std.testing.expect(!wg.isDone());
    try std.testing.expectEqual(@as(usize, 10), wg.remaining());

    var i: usize = 0;
    while (i < 10) : (i += 1) try wg.done();
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 0), wg.remaining());
}

test "waitgroup underflow returns error" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    try std.testing.expectError(error.Underflow, wg.done());
}

test "waitgroup done after add underflow" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(2);
    try wg.done();
    try wg.done();
    try std.testing.expectError(error.Underflow, wg.done());
}

test "waitgroup onComplete callback fires when reaching zero" {
    const Ctx = struct {
        var fired: bool = false;
        fn cb(_: ?*anyopaque) void {
            fired = true;
        }
    };
    Ctx.fired = false;

    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(3);

    try wg.done();
    try std.testing.expect(!Ctx.fired);
    try wg.done();
    try std.testing.expect(!Ctx.fired);
    try wg.done();
    try std.testing.expect(Ctx.fired);
}

test "waitgroup onComplete does not fire if never reaches zero" {
    const Ctx = struct {
        var fired: bool = false;
        fn cb(_: ?*anyopaque) void {
            fired = true;
        }
    };
    Ctx.fired = false;

    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(5);
    try wg.done();
    try wg.done();
    try std.testing.expect(!Ctx.fired);
}

test "waitgroup reset clears state" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(5);
    try wg.done();
    wg.reset();
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 0), wg.remaining());
}

test "waitgroup fresh instance isDone is true" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 0), wg.remaining());
}

test "waitgroup multiple add calls accumulate" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(3);
    wg.add(2);
    wg.add(5);
    try std.testing.expectEqual(@as(usize, 10), wg.remaining());

    var i: usize = 0;
    while (i < 10) : (i += 1) try wg.done();
    try std.testing.expect(wg.isDone());
}

test "waitgroup onComplete callback receives context" {
    const Ctx = struct {
        result: usize,
    };
    const handler = struct {
        fn cb(raw: ?*anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw orelse return));
            ctx.result = 99;
        }
    }.cb;

    var ctx = Ctx{ .result = 0 };
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(handler, &ctx);
    wg.add(1);
    try wg.done();
    try std.testing.expectEqual(@as(usize, 99), ctx.result);
}

test "waitgroup reset then reuse" {
    const Ctx = struct {
        var count: usize = 0;
        fn cb(_: ?*anyopaque) void {
            count += 1;
        }
    };
    Ctx.count = 0;

    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(1);
    try wg.done();
    try std.testing.expectEqual(@as(usize, 1), Ctx.count);

    wg.reset();
    wg.onComplete(Ctx.cb, null);
    wg.add(2);
    try wg.done();
    try wg.done();
    try std.testing.expectEqual(@as(usize, 2), Ctx.count);
}

test "waitgroup done on reset waitgroup returns underflow" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.add(3);
    wg.reset();
    try std.testing.expectError(error.Underflow, wg.done());
}

test "waitgroup onComplete does not fire on intermediate done" {
    const Ctx = struct {
        var fired_at: ?usize = null;
        var call_seq: usize = 0;
        fn cb(_: ?*anyopaque) void {
            fired_at = call_seq;
        }
    };
    Ctx.fired_at = null;
    Ctx.call_seq = 0;

    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(3);

    try wg.done();
    Ctx.call_seq = 1;
    try std.testing.expect(Ctx.fired_at == null);

    try wg.done();
    Ctx.call_seq = 2;
    try std.testing.expect(Ctx.fired_at == null);

    try wg.done();
    try std.testing.expectEqual(@as(usize, 2), Ctx.fired_at.?);
}

test "waitgroup add zero keeps done state unchanged" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();

    try std.testing.expect(wg.isDone());
    wg.add(0);
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 0), wg.remaining());
}

test "waitgroup wait on zero pending returns immediately" {
    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();

    wg.wait();
    try std.testing.expect(wg.isDone());
}

test "waitgroup latest callback overrides previous registration" {
    const Ctx = struct {
        var a: usize = 0;
        var b: usize = 0;
        fn cbA(_: ?*anyopaque) void {
            a += 1;
        }
        fn cbB(_: ?*anyopaque) void {
            b += 1;
        }
    };
    Ctx.a = 0;
    Ctx.b = 0;

    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cbA, null);
    wg.onComplete(Ctx.cbB, null);
    wg.add(1);
    try wg.done();

    try std.testing.expectEqual(@as(usize, 0), Ctx.a);
    try std.testing.expectEqual(@as(usize, 1), Ctx.b);
}

test "waitgroup reset clears callback registration" {
    const Ctx = struct {
        var fired: usize = 0;
        fn cb(_: ?*anyopaque) void {
            fired += 1;
        }
    };
    Ctx.fired = 0;

    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);
    wg.add(1);
    wg.reset();
    wg.add(1);
    try wg.done();

    try std.testing.expectEqual(@as(usize, 0), Ctx.fired);
}

test "waitgroup supports multiple completion cycles" {
    const Ctx = struct {
        var fired: usize = 0;
        fn cb(_: ?*anyopaque) void {
            fired += 1;
        }
    };
    Ctx.fired = 0;

    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();
    wg.onComplete(Ctx.cb, null);

    wg.add(1);
    try wg.done();
    wg.add(2);
    try wg.done();
    try wg.done();

    try std.testing.expectEqual(@as(usize, 2), Ctx.fired);
    try std.testing.expect(wg.isDone());
}

test "waitgroup callback can be registered after first completion" {
    const Ctx = struct {
        var fired: usize = 0;
        fn cb(_: ?*anyopaque) void {
            fired += 1;
        }
    };
    Ctx.fired = 0;

    var wg = WaitGroup(runtime.std.Mutex, runtime.std.Condition).init();
    defer wg.deinit();

    wg.add(1);
    try wg.done();
    wg.onComplete(Ctx.cb, null);
    wg.add(1);
    try wg.done();

    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
}
