//! Racer test runner — exercises first-winner semantics and wait behavior.
//!
//! Accepts any type with the same shape as std
//! (lib.Thread, lib.atomic, lib.mem, lib.meta).
//! Can be compiled into firmware main.zig — no reliance on file-scope tests.
//!
//! Usage:
//!   try @import("sync").test_runner.racer.run(std);
//!   try @import("sync").test_runner.racer.run(embed);

const root = @import("../../sync.zig");
const context_mod = @import("context");

pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.racer);

    log.info("=== racer test_runner start ===", .{});

    try spawnAllocatorTests(lib);
    try firstWinnerTests(lib);
    try raceContextTests(lib);
    try doneAndWaitTests(lib);
    try exhaustedTests(lib);
    try initOomTests(lib);

    log.info("=== racer test_runner done ===", .{});
}

fn firstWinnerTests(comptime lib: type) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);

    var racer = try R.init(testing.allocator);
    defer racer.deinit();

    try racer.spawn(.{}, struct {
        fn run(ctx: R.State, l: type, delay_ms: u64, value: u32) void {
            l.Thread.sleep(delay_ms * l.time.ns_per_ms);
            _ = ctx.success(value);
        }
    }.run, .{ lib, 20, 2 });

    try racer.spawn(.{}, struct {
        fn run(ctx: R.State, l: type, delay_ms: u64, value: u32) void {
            l.Thread.sleep(delay_ms * l.time.ns_per_ms);
            _ = ctx.success(value);
        }
    }.run, .{ lib, 5, 1 });

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 1), value),
        .exhausted => return error.ExpectedWinner,
    }

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 1), value),
        .exhausted => return error.ExpectedWinner,
    }

    try testing.expect(racer.done());
    try testing.expectEqual(@as(?u32, 1), racer.value());

    racer.wait();
    racer.wait();
}

fn raceContextTests(comptime lib: type) !void {
    const testing = lib.testing;
    const Context = context_mod.Make(lib);
    var context = try Context.init(testing.allocator);
    defer context.deinit();
    const R = root.Racer(lib, u32);

    {
        var racer = try R.init(testing.allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                _ = state.success(3);
            }
        }.run, .{lib});

        switch (try racer.raceContext(context.background())) {
            .winner => |value| try testing.expectEqual(@as(u32, 3), value),
            .exhausted => return error.ExpectedWinner,
        }
    }

    {
        var racer = try R.init(testing.allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                _ = state;
                l.Thread.sleep(20 * l.time.ns_per_ms);
            }
        }.run, .{lib});

        var cancel_ctx = try context.withCancel(context.background());
        defer cancel_ctx.deinit();
        cancel_ctx.cancel();

        try testing.expectError(error.Canceled, racer.raceContext(cancel_ctx));
    }

    {
        var racer = try R.init(testing.allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                _ = state.success(11);
            }
        }.run, .{lib});

        var timeout_ctx = try context.withTimeout(context.background(), 200);
        defer timeout_ctx.deinit();

        switch (try racer.raceContext(timeout_ctx)) {
            .winner => |value| try testing.expectEqual(@as(u32, 11), value),
            .exhausted => return error.ExpectedWinner,
        }
    }

    {
        var racer = try R.init(testing.allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                _ = state.success(21);
            }
        }.run, .{lib});

        switch (racer.race()) {
            .winner => |value| try testing.expectEqual(@as(u32, 21), value),
            .exhausted => return error.ExpectedWinner,
        }

        var cancel_ctx = try context.withCancel(context.background());
        defer cancel_ctx.deinit();
        cancel_ctx.cancelWithCause(error.BrokenPipe);

        // This is intentional: an already-canceled external context takes
        // precedence over a previously published winner for raceContext().
        try testing.expectError(error.BrokenPipe, racer.raceContext(cancel_ctx));

        switch (racer.race()) {
            .winner => |value| try testing.expectEqual(@as(u32, 21), value),
            .exhausted => return error.ExpectedWinner,
        }
    }

    {
        var racer = try R.init(testing.allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                _ = state;
                l.Thread.sleep(50 * l.time.ns_per_ms);
            }
        }.run, .{lib});

        var timeout_ctx = try context.withTimeout(context.background(), 5);
        defer timeout_ctx.deinit();

        try testing.expectError(error.DeadlineExceeded, racer.raceContext(timeout_ctx));
    }

    {
        var racer = try R.init(testing.allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                _ = state;
                l.Thread.sleep(20 * l.time.ns_per_ms);
            }
        }.run, .{lib});

        var cancel_ctx = try context.withCancel(context.background());
        defer cancel_ctx.deinit();

        var cancel_thread = try lib.Thread.spawn(.{}, struct {
            fn run(cc: *context_mod.Context, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                cc.cancelWithCause(error.BrokenPipe);
            }
        }.run, .{ &cancel_ctx, lib });
        defer cancel_thread.join();

        try testing.expectError(error.BrokenPipe, racer.raceContext(cancel_ctx));
    }
}

fn exhaustedTests(comptime lib: type) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);

    var racer = try R.init(testing.allocator);
    defer racer.deinit();

    try racer.spawn(.{}, struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    switch (racer.race()) {
        .winner => return error.UnexpectedWinner,
        .exhausted => {},
    }

    switch (racer.race()) {
        .winner => return error.UnexpectedWinner,
        .exhausted => {},
    }

    try testing.expect(!racer.done());
    try testing.expectEqual(@as(?u32, null), racer.value());

    racer.wait();
    racer.wait();
}

fn doneAndWaitTests(comptime lib: type) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);
    const BoolAtomic = lib.atomic.Value(bool);

    const Flags = struct {
        saw_done: BoolAtomic = BoolAtomic.init(false),
        allow_exit: BoolAtomic = BoolAtomic.init(false),
        finished: BoolAtomic = BoolAtomic.init(false),
        winner_rejected: BoolAtomic = BoolAtomic.init(false),
    };

    var racer = try R.init(testing.allocator);
    defer racer.deinit();

    var flags = Flags{};

    try racer.spawn(.{}, struct {
        fn run(ctx: R.State, l: type, f: *Flags) void {
            while (!ctx.done()) {
                l.Thread.sleep(l.time.ns_per_ms);
            }

            f.saw_done.store(true, .release);
            f.winner_rejected.store(!ctx.success(99), .release);

            while (!f.allow_exit.load(.acquire)) {
                l.Thread.sleep(l.time.ns_per_ms);
            }

            f.finished.store(true, .release);
        }
    }.run, .{ lib, &flags });

    try racer.spawn(.{}, struct {
        fn run(ctx: R.State, l: type) void {
            l.Thread.sleep(5 * l.time.ns_per_ms);
            _ = ctx.success(7);
        }
    }.run, .{lib});

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 7), value),
        .exhausted => return error.ExpectedWinner,
    }

    try testing.expect(racer.done());
    try testing.expectEqual(@as(?u32, 7), racer.value());

    try waitForTrue(lib, &flags.saw_done, 200);
    try testing.expect(!flags.finished.load(.acquire));
    try testing.expect(flags.winner_rejected.load(.acquire));

    flags.allow_exit.store(true, .release);
    racer.wait();
    racer.wait();

    try testing.expect(flags.finished.load(.acquire));
}

fn spawnAllocatorTests(comptime lib: type) !void {
    const tst = lib.testing;
    const CapturingThread = CapturingThreadType(lib);
    const PassthroughAllocator = PassthroughAllocatorType(lib);
    const CapturingThreadLib = struct {
        pub const mem = lib.mem;
        pub const atomic = lib.atomic;
        pub const testing = lib.testing;
        pub const debug = lib.debug;
        pub const Thread = CapturingThread;
    };
    const R = root.Racer(CapturingThreadLib, u32);

    var racer = try R.init(tst.allocator);
    defer racer.deinit();

    CapturingThread.last_allocator = null;
    try racer.spawn(.{}, struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    const seen_default = CapturingThread.last_allocator orelse return error.ExpectedDefaultAllocator;
    try tst.expect(lib.meta.eql(seen_default, tst.allocator));

    var explicit_allocator_state = PassthroughAllocator.init(tst.allocator);
    const explicit_allocator = explicit_allocator_state.allocator();

    CapturingThread.last_allocator = null;
    try racer.spawn(.{ .allocator = explicit_allocator }, struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    const seen_explicit = CapturingThread.last_allocator orelse return error.ExpectedExplicitAllocator;
    try tst.expect(lib.meta.eql(seen_explicit, explicit_allocator));
}

fn initOomTests(comptime lib: type) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);
    const FailingAllocator = FailingAllocatorType(lib);

    var failing_allocator = FailingAllocator{};

    try testing.expectError(error.OutOfMemory, R.init(failing_allocator.allocator()));
}

fn waitForTrue(comptime lib: type, flag: *lib.atomic.Value(bool), timeout_ms: u64) !void {
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < timeout_ms) : (elapsed_ms += 1) {
        if (flag.load(.acquire)) return;
        lib.Thread.sleep(lib.time.ns_per_ms);
    }
    return error.TimeoutWaitingForFlag;
}

fn allocatorAlignment(comptime lib: type) type {
    const alloc_ptr_type = @TypeOf(lib.testing.allocator.vtable.alloc);
    const alloc_fn_type = @typeInfo(alloc_ptr_type).pointer.child;
    return @typeInfo(alloc_fn_type).@"fn".params[2].type.?;
}

fn PassthroughAllocatorType(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Alignment = allocatorAlignment(lib);

    return struct {
        backing: Allocator,

        const Self = @This();

        pub fn init(backing: Allocator) Self {
            return .{ .backing = backing };
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };
}

fn FailingAllocatorType(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Alignment = allocatorAlignment(lib);

    return struct {
        const Self = @This();

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn alloc(_: *anyopaque, _: usize, _: Alignment, _: usize) ?[*]u8 {
            return null;
        }

        fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
            return false;
        }

        fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }

        fn free(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {}

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };
}

fn CapturingThreadType(comptime lib: type) type {
    return struct {
        pub const Mutex = lib.Thread.Mutex;
        pub const Condition = lib.Thread.Condition;
        pub const SpawnError = error{};
        pub const SpawnConfig = struct {
            allocator: ?lib.mem.Allocator = null,
        };

        pub var last_allocator: ?lib.mem.Allocator = null;

        const Self = @This();

        pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Self {
            last_allocator = config.allocator;
            @call(.auto, f, args);
            return .{};
        }

        pub fn detach(self: Self) void {
            _ = self;
        }
    };
}

test "std_compat" {
    const std = @import("std");
    try run(std);
}
