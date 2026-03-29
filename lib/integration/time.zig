const embed = @import("embed");
const testing_mod = @import("testing");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runImpl(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type) !void {
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
