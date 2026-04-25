const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const Context = context_root.Context;
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("err_is_null", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try backgroundErrIsNullCase(lib, case_allocator);
                }
            }.run));
            t.run("value_is_empty", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try backgroundValueIsEmptyCase(lib, case_allocator);
                }
            }.run));
            t.run("deadline_is_null", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try backgroundDeadlineIsNullCase(lib, case_allocator);
                }
            }.run));
            t.run("wait_uses_thread_sleep", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try backgroundWaitUsesThreadSleepCase(lib, case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}

fn backgroundErrIsNullCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    if (bg.err() != null) return error.BackgroundShouldNotBeDone;
}

fn backgroundValueIsEmptyCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    if (bg.value(u64, &key) != null) return error.BackgroundShouldHaveNoValues;
}

fn backgroundDeadlineIsNullCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    if (bg.deadline() != null) return error.BackgroundShouldHaveNoDeadline;
}

fn backgroundWaitUsesThreadSleepCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CapturingThread = test_utils.CapturingSleepThreadType(lib);
    const FakeLib = struct {
        pub const Thread = CapturingThread;
        pub const time = lib.time;
        pub const mem = lib.mem;
        pub const DoublyLinkedList = lib.DoublyLinkedList;
    };
    const FakeCtxApi = context_root.make(FakeLib);
    var fake_ctx_ns = try FakeCtxApi.init(allocator);
    defer fake_ctx_ns.deinit();

    CapturingThread.sleep_calls = 0;
    CapturingThread.last_sleep_ns = 0;
    if (fake_ctx_ns.background().wait(5 * lib.time.ns_per_ms) != null) return error.BackgroundWaitShouldReturnNull;
    if (CapturingThread.sleep_calls == 0) return error.BackgroundWaitShouldUseLibThreadSleep;
    if (CapturingThread.last_sleep_ns != 5 * lib.time.ns_per_ms) return error.BackgroundWaitWrongSleepDuration;
}
