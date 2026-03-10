const std = @import("std");
const hal = struct {
    pub const led_strip = @import("../../../hal/led_strip.zig");
};
const frame_mod = @import("frame.zig");

pub const Color = hal.led_strip.Color;

pub fn stepChannel(cur: u8, tgt: u8, amount: u8) u8 {
    if (cur < tgt) {
        return if (tgt - cur <= amount) tgt else cur + amount;
    } else if (cur > tgt) {
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

/// Step every pixel in `current` toward `target` by `amount`.
/// Returns true if any pixel changed.
pub fn stepFrame(comptime n: u32, current: *frame_mod.Frame(n), target: frame_mod.Frame(n), amount: u8) bool {
    var changed = false;
    for (&current.pixels, target.pixels) |*cur, tgt| {
        if (!colorEql(cur.*, tgt)) {
            cur.* = stepToward(cur.*, tgt, amount);
            changed = true;
        }
    }
    return changed;
}

/// Lerp every pixel in `current` toward `target` by dividing the remaining
/// distance into `remaining_steps` segments (matching the old C design).
/// Returns true if any pixel changed.
pub fn lerpFrame(comptime n: u32, current: *frame_mod.Frame(n), target: frame_mod.Frame(n), remaining_steps: u8) bool {
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Frame = frame_mod.Frame;

test "stepToward: reaches target" {
    var c = Color.black;
    const target = Color.rgb(50, 100, 150);
    for (0..256) |_| {
        c = stepToward(c, target, 5);
    }
    try testing.expectEqual(target, c);
}

test "stepToward: single step within range snaps" {
    const c = Color.rgb(3, 3, 3);
    const t = Color.black;
    const r = stepToward(c, t, 5);
    try testing.expectEqual(Color.black, r);
}

test "stepFrame: converges" {
    const F = Frame(4);
    var current = F.solid(Color.black);
    const target = F.solid(Color.red);
    var steps: u32 = 0;
    while (!current.eql(target)) : (steps += 1) {
        _ = stepFrame(4, &current, target, 10);
        if (steps > 100) break;
    }
    try testing.expect(current.eql(target));
}

test "lerpFrame: remaining=1 snaps to target" {
    const F = Frame(2);
    var current = F.solid(Color.black);
    const target = F.solid(Color.white);
    const changed = lerpFrame(2, &current, target, 1);
    try testing.expect(changed);
    try testing.expect(current.eql(target));
}

test "lerpFrame: converges over steps" {
    const F = Frame(2);
    var current = F.solid(Color.black);
    const target = F.solid(Color.rgb(100, 200, 50));
    for (0..64) |_| {
        _ = lerpFrame(2, &current, target, 8);
    }
    try testing.expect(current.eql(target));
}
