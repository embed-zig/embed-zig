//! ledstrip.Transition — helpers for moving frames toward new target colors.

const Color = @import("Color.zig");
const Frame = @import("Frame.zig");

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

test "ledstrip/unit_tests/Transition_stepToward_reaches_target" {
    const std = @import("std");

    var color = Color.black;
    const target = Color.rgb(50, 100, 150);

    for (0..256) |_| {
        color = stepToward(color, target, 5);
    }

    try std.testing.expectEqual(target, color);
}

test "ledstrip/unit_tests/Transition_stepToward_snaps_when_within_range" {
    const std = @import("std");

    const current = Color.rgb(3, 3, 3);
    const target = Color.black;
    const stepped = stepToward(current, target, 5);

    try std.testing.expectEqual(Color.black, stepped);
}

test "ledstrip/unit_tests/Transition_stepFrame_converges" {
    const std = @import("std");

    const F = Frame.make(4);
    var current = F.solid(Color.black);
    const target = F.solid(Color.red);

    var steps: u32 = 0;
    while (!current.eql(target)) : (steps += 1) {
        _ = stepFrame(4, &current, target, 10);
        if (steps > 100) break;
    }

    try std.testing.expect(current.eql(target));
}

test "ledstrip/unit_tests/Transition_stepFrame_reports_no_change_when_already_equal" {
    const std = @import("std");

    const F = Frame.make(2);
    var current = F.solid(Color.green);
    const target = F.solid(Color.green);

    try std.testing.expect(!stepFrame(2, &current, target, 8));
}

test "ledstrip/unit_tests/Transition_lerpFrame_remaining_one_snaps_to_target" {
    const std = @import("std");

    const F = Frame.make(2);
    var current = F.solid(Color.black);
    const target = F.solid(Color.white);

    try std.testing.expect(lerpFrame(2, &current, target, 1));
    try std.testing.expect(current.eql(target));
}

test "ledstrip/unit_tests/Transition_lerpFrame_converges_over_steps" {
    const std = @import("std");

    const F = Frame.make(2);
    var current = F.solid(Color.black);
    const target = F.solid(Color.rgb(100, 200, 50));

    for (0..64) |_| {
        _ = lerpFrame(2, &current, target, 8);
    }

    try std.testing.expect(current.eql(target));
}
