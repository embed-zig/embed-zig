const std = @import("std");
const module = @import("transition.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const frame_mod = @import("frame.zig");
const Color = module.Color;
const stepChannel = module.stepChannel;
const stepToward = module.stepToward;
const colorEql = module.colorEql;
const stepFrame = module.stepFrame;
const lerpFrame = module.lerpFrame;

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
