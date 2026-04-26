//! lvgl animation test runner — tick, timer handler, and animation smoke tests.
//!
//! Usage:
//!   const runner = @import("lvgl/test_runner/integration/lvgl/anim.zig").make(std);

const embed = @import("embed");
const testing = @import("testing");
const lvgl = @import("../../../../lvgl.zig");

const Tick = lvgl.Tick;
const Anim = lvgl.Anim;

pub fn make(comptime lib: type) testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const test_lib = lib.testing;

            const Cases = struct {
                fn tickIncAndElaps() !void {
                    lvgl.init();
                    defer lvgl.deinit();

                    const t0 = Tick.get();
                    Tick.inc(33);
                    try test_lib.expect(Tick.elaps(t0) >= 33);
                }

                fn timerHandlerSmoke() !void {
                    lvgl.init();
                    defer lvgl.deinit();

                    Tick.inc(1);
                    const next = Tick.timerHandler();
                    try test_lib.expectEqual(Tick.no_timer_ready, next);
                }

                fn animationRunsWithTickAndTimer() !void {
                    lvgl.init();
                    defer lvgl.deinit();

                    var current: i32 = -1;
                    var anim = try Anim.init();
                    defer anim.deinit();

                    anim.setVar(&current);
                    anim.setExecCb(animExecForTickTest);
                    anim.setDuration(40);
                    anim.setValues(0, 100);
                    anim.setRepeatCount(1);

                    _ = anim.start();
                    try test_lib.expectEqual(@as(i32, 0), current);

                    var i: u32 = 0;
                    while (current < 100 and i < 32) : (i += 1) {
                        Tick.inc(10);
                        _ = Tick.timerHandler();
                    }

                    try test_lib.expectEqual(@as(i32, 100), current);
                }
            };

            Cases.tickIncAndElaps() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.timerHandlerSmoke() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.animationRunsWithTickAndTimer() catch |err| {
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
    return testing.TestRunner.make(Runner).new(runner);
}

fn animExecForTickTest(var_: ?*anyopaque, value: i32) callconv(.c) void {
    const p: *i32 = @ptrCast(@alignCast(var_.?));
    p.* = value;
}
