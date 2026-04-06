//! ledstrip.Transition — helpers for moving frames toward new target colors.

const Color = @import("Color.zig");
const Frame = @import("Frame.zig");
const testing_api = @import("testing");

pub fn stepChannel(cur: u8, tgt: u8, amount: u8) u8 {
    if (cur < tgt) {
        return if (tgt - cur <= amount) tgt else cur + amount;
    }
    if (cur > tgt) {
        return if (cur - tgt <= amount) tgt else cur - amount;
    }
    return cur;
}

pub fn stepToward(current: Color, target: Color, amount: u8) Color {
    return .{
        .r = stepChannel(current.r, target.r, amount),
        .g = stepChannel(current.g, target.g, amount),
        .b = stepChannel(current.b, target.b, amount),
    };
}

pub fn colorEql(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

pub fn stepFrame(comptime n: usize, current: *Frame.make(n), target: Frame.make(n), amount: u8) bool {
    var changed = false;

    for (&current.pixels, target.pixels) |*cur, tgt| {
        if (!colorEql(cur.*, tgt)) {
            cur.* = stepToward(cur.*, tgt, amount);
            changed = true;
        }
    }

    return changed;
}

pub fn lerpFrame(comptime n: usize, current: *Frame.make(n), target: Frame.make(n), remaining_steps: u8) bool {
    if (remaining_steps <= 1) {
        const changed = !current.eql(target);
        current.* = target;
        return changed;
    }

    var changed = false;
    for (&current.pixels, target.pixels) |*cur, tgt| {
        if (!colorEql(cur.*, tgt)) {
            cur.r = lerpChannel(cur.r, tgt.r, remaining_steps);
            cur.g = lerpChannel(cur.g, tgt.g, remaining_steps);
            cur.b = lerpChannel(cur.b, tgt.b, remaining_steps);
            changed = true;
        }
    }

    return changed;
}

fn lerpChannel(cur: u8, tgt: u8, steps: u8) u8 {
    const diff = @as(i16, tgt) - @as(i16, cur);
    const step = @divTrunc(diff, @as(i16, steps));
    if (step == 0) return tgt;
    return @intCast(@as(i16, cur) + step);
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn stepTowardReachesTarget() !void {
            var color = Color.black;
            const target = Color.rgb(50, 100, 150);

            for (0..256) |_| {
                color = stepToward(color, target, 5);
            }

            try lib.testing.expectEqual(target, color);
        }

        fn stepTowardSnapsWhenWithinRange() !void {
            const current = Color.rgb(3, 3, 3);
            const target = Color.black;
            const stepped = stepToward(current, target, 5);

            try lib.testing.expectEqual(Color.black, stepped);
        }

        fn stepFrameConverges() !void {
            const F = Frame.make(4);
            var current = F.solid(Color.black);
            const target = F.solid(Color.red);

            var steps: u32 = 0;
            while (!current.eql(target)) : (steps += 1) {
                _ = stepFrame(4, &current, target, 10);
                if (steps > 100) break;
            }

            try lib.testing.expect(current.eql(target));
        }

        fn stepFrameReportsNoChangeWhenAlreadyEqual() !void {
            const F = Frame.make(2);
            var current = F.solid(Color.green);
            const target = F.solid(Color.green);

            try lib.testing.expect(!stepFrame(2, &current, target, 8));
        }

        fn lerpFrameRemainingOneSnapsToTarget() !void {
            const F = Frame.make(2);
            var current = F.solid(Color.black);
            const target = F.solid(Color.white);

            try lib.testing.expect(lerpFrame(2, &current, target, 1));
            try lib.testing.expect(current.eql(target));
        }

        fn lerpFrameConvergesOverSteps() !void {
            const F = Frame.make(2);
            var current = F.solid(Color.black);
            const target = F.solid(Color.rgb(100, 200, 50));

            for (0..64) |_| {
                _ = lerpFrame(2, &current, target, 8);
            }

            try lib.testing.expect(current.eql(target));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.stepTowardReachesTarget() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.stepTowardSnapsWhenWithinRange() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.stepFrameConverges() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.stepFrameReportsNoChangeWhenAlreadyEqual() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.lerpFrameRemainingOneSnapsToTarget() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.lerpFrameConvergesOverSteps() catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
