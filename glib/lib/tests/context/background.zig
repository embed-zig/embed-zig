const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const time_mod = @import("time");
const Context = context_root.Context;
const context_std = @import("std.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime std: type, comptime time: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("err_is_null", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try backgroundErrIsNullCase(std, time, case_allocator);
                }
            }.run));
            t.run("value_is_empty", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try backgroundValueIsEmptyCase(std, time, case_allocator);
                }
            }.run));
            t.run("deadline_is_null", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try backgroundDeadlineIsNullCase(std, time, case_allocator);
                }
            }.run));
            t.run("wait_uses_time_sleep", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try backgroundWaitUsesTimeSleepCase(std, time, case_allocator);
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

fn backgroundErrIsNullCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    if (bg.err() != null) return error.BackgroundShouldNotBeDone;
}

fn backgroundValueIsEmptyCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_api.background();
    if (bg.value(u64, &key) != null) return error.BackgroundShouldHaveNoValues;
}

fn backgroundDeadlineIsNullCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    if (bg.deadline() != null) return error.BackgroundShouldHaveNoDeadline;
}

fn backgroundWaitUsesTimeSleepCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CapturingTime = struct {
        pub const instant = time.instant;

        pub var sleep_calls: usize = 0;
        pub var last_sleep_ns: u64 = 0;

        pub fn sleep(duration: time_mod.duration.Duration) void {
            sleep_calls += 1;
            last_sleep_ns = @intCast(duration);
            time.sleep(duration);
        }

        pub fn sleepNanos(ns: u64) void {
            sleep_calls += 1;
            last_sleep_ns = ns;
            time.sleepNanos(ns);
        }
    };

    const FakeLib = context_std.make(std, .{});
    const FakeCtxApi = context_root.make(FakeLib, CapturingTime);
    var fake_ctx_api = try FakeCtxApi.init(allocator);
    defer fake_ctx_api.deinit();

    CapturingTime.sleep_calls = 0;
    CapturingTime.last_sleep_ns = 0;
    if (fake_ctx_api.background().wait(5 * time_mod.duration.MilliSecond) != null) return error.BackgroundWaitShouldReturnNull;
    if (CapturingTime.sleep_calls == 0) return error.BackgroundWaitShouldUseRuntimeTimeSleep;
    if (CapturingTime.last_sleep_ns != 5 * time_mod.duration.MilliSecond) return error.BackgroundWaitWrongSleepDuration;
}
