const stdz = @import("stdz");
const testing_mod = @import("testing");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("timer_clamps_backward_jumps", testing_mod.TestRunner.fromFn(lib, 16 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try timerClampsBackwardJumpsCase(lib);
                }
            }.run));
            t.run("timer_saturates_elapsed_to_u64_max", testing_mod.TestRunner.fromFn(lib, 16 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try timerSaturatesElapsedToU64MaxCase(lib);
                }
            }.run));
            t.run("timer_handles_i128_delta_overflow", testing_mod.TestRunner.fromFn(lib, 16 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try timerHandlesI128DeltaOverflowCase(lib);
                }
            }.run));
            t.run("real_clock", testing_mod.TestRunner.fromFn(lib, 40 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try realClockCase(lib);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn timerClampsBackwardJumpsCase(comptime lib: type) !void {
    const TimeApi = @import("stdz").time;

    const Impl = struct {
        pub var index: usize = 0;
        pub const samples = [_]i128{ 100, 110, 105, 120, 115 };

        pub fn milliTimestamp() i64 {
            return 0;
        }

        pub fn nanoTimestamp() i128 {
            defer index += 1;
            return samples[index];
        }
    };

    const time = TimeApi.make(Impl);
    Impl.index = 0;

    var timer = try time.Timer.start();
    try lib.testing.expectEqual(@as(u64, 10), timer.read());
    try lib.testing.expectEqual(@as(u64, 10), timer.read());
    try lib.testing.expectEqual(@as(u64, 20), timer.lap());
    try lib.testing.expectEqual(@as(u64, 0), timer.read());
}

fn timerSaturatesElapsedToU64MaxCase(comptime lib: type) !void {
    const std = @import("std");
    const TimeApi = @import("stdz").time;

    const max_u64_ns: i128 = @intCast(std.math.maxInt(u64));
    const Impl = struct {
        pub var index: usize = 0;
        pub const samples = [_]i128{ 0, max_u64_ns + 123 };

        pub fn milliTimestamp() i64 {
            return 0;
        }

        pub fn nanoTimestamp() i128 {
            defer index += 1;
            return samples[index];
        }
    };

    const time = TimeApi.make(Impl);
    Impl.index = 0;

    var timer = try time.Timer.start();
    try lib.testing.expectEqual(std.math.maxInt(u64), timer.read());
}

fn timerHandlesI128DeltaOverflowCase(comptime lib: type) !void {
    const std = @import("std");
    const TimeApi = @import("stdz").time;

    const min_i128 = std.math.minInt(i128);
    const max_i128 = std.math.maxInt(i128);

    const Impl = struct {
        pub var index: usize = 0;
        pub const samples = [_]i128{ min_i128 + 1, max_i128 - 1 };

        pub fn milliTimestamp() i64 {
            return 0;
        }

        pub fn nanoTimestamp() i128 {
            defer index += 1;
            return samples[index];
        }
    };

    const time = TimeApi.make(Impl);
    Impl.index = 0;

    var timer = try time.Timer.start();
    try lib.testing.expectEqual(std.math.maxInt(u64), timer.read());
}

fn realClockCase(comptime lib: type) !void {
    const t1 = lib.time.milliTimestamp();
    lib.Thread.sleep(10_000_000);
    const t2 = lib.time.milliTimestamp();
    const elapsed = t2 - t1;
    if (elapsed < 5) return error.TimestampTooFast;

    if (t1 <= 0) return error.TimestampNonPositive;

    const ns1 = lib.time.nanoTimestamp();
    lib.Thread.sleep(1_000_000);
    const ns2 = lib.time.nanoTimestamp();
    const elapsed_ns = ns2 - ns1;
    if (elapsed_ns <= 0) return error.NanoTimestampNonMonotonic;

    {
        var timer = try lib.time.Timer.start();
        lib.Thread.sleep(10_000_000);
        const r1 = timer.read();
        if (r1 < 5 * lib.time.ns_per_ms) return error.TimerReadTooSmall;

        const lap_val = timer.lap();
        if (lap_val < r1) return error.TimerLapTooSmall;

        lib.Thread.sleep(1_000_000);
        const after_lap = timer.read();
        if (after_lap >= lap_val) return error.TimerLapDidNotReset;
        if (after_lap < lib.time.ns_per_ms / 2) return error.TimerLapReadTooSmall;

        timer.reset();
        lib.Thread.sleep(1_000_000);
        const after_reset = timer.read();
        if (after_reset >= lap_val) return error.TimerResetFailed;
        if (after_reset < lib.time.ns_per_ms / 2) return error.TimerResetReadTooSmall;
    }
}
