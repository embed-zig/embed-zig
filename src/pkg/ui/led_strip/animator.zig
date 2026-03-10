const std = @import("std");
const frame_mod = @import("frame.zig");
const transition = @import("transition.zig");

pub const Color = frame_mod.Color;

/// Multi-frame LED strip animator with inter-frame transitions.
///
/// `n` — number of LEDs.
/// `max_frames` — maximum animation frames (comptime).
///
/// The animator holds a sequence of target frames. Each tick:
///   1. Advance frame index when interval_ticks is reached.
///   2. Lerp `current` toward the active target frame.
///
/// `current` always holds the actual output to flush to hardware.
pub fn Animator(comptime n: u32, comptime max_frames: u32) type {
    const FrameType = frame_mod.Frame(n);

    return struct {
        const Self = @This();
        pub const pixel_count = n;
        pub const Frame = FrameType;

        frames: [max_frames]FrameType = [_]FrameType{.{}} ** max_frames,
        total_frames: u8 = 0,
        current_frame: u8 = 0,
        interval_ticks: u8 = 16,
        tick_count: u8 = 0,
        step_amount: u8 = 5,

        current: FrameType = .{},
        brightness: u8 = 255,

        /// Advance animation by one tick. Returns true if `current` changed.
        pub fn tick(self: *Self) bool {
            if (self.total_frames == 0) return false;

            self.tick_count += 1;
            if (self.tick_count >= self.interval_ticks) {
                self.tick_count = 0;
                self.current_frame = (self.current_frame + 1) % self.total_frames;
            }

            var target = self.frames[self.current_frame];
            if (self.brightness < 255) {
                target = target.withBrightness(self.brightness);
            }

            return transition.stepFrame(n, &self.current, target, self.step_amount);
        }

        // ----------------------------------------------------------------
        // Preset constructors
        // ----------------------------------------------------------------

        /// Static: transition to a single frame and hold.
        pub fn fixed(f: FrameType) Self {
            var self = Self{};
            self.frames[0] = f;
            self.total_frames = 1;
            self.interval_ticks = 16;
            return self;
        }

        /// Flash: alternate between frame and black.
        pub fn flash(f: FrameType, interval: u8) Self {
            var self = Self{};
            self.frames[0] = f;
            self.frames[1] = .{};
            self.total_frames = 2;
            self.interval_ticks = interval;
            return self;
        }

        /// Ping-pong between two frames.
        pub fn pingpong(from: FrameType, to: FrameType, interval: u8) Self {
            var self = Self{};
            self.frames[0] = from;
            self.frames[1] = to;
            self.total_frames = 2;
            self.interval_ticks = interval;
            return self;
        }

        /// Rotate: generate N rotated versions of a frame.
        pub fn rotateAnim(f: FrameType, interval: u8) Self {
            var self = Self{};
            const count = @min(n, max_frames);
            self.frames[0] = f;
            for (1..count) |i| {
                self.frames[i] = self.frames[i - 1].rotate();
            }
            self.total_frames = @intCast(count);
            self.interval_ticks = interval;
            return self;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Frame = frame_mod.Frame;

test "Animator: fixed converges to target" {
    const F = Frame(4);
    const Anim = Animator(4, 4);
    var anim = Anim.fixed(F.solid(Color.red));
    anim.step_amount = 50;

    var ticks: u32 = 0;
    while (!anim.current.eql(F.solid(Color.red))) : (ticks += 1) {
        _ = anim.tick();
        if (ticks > 100) break;
    }
    try testing.expect(anim.current.eql(F.solid(Color.red)));
}

test "Animator: flash alternates" {
    const F = Frame(1);
    const Anim = Animator(1, 4);
    var anim = Anim.flash(F.solid(Color.white), 2);
    anim.step_amount = 255;

    _ = anim.tick();
    _ = anim.tick();
    const after_first_interval = anim.current;

    _ = anim.tick();
    _ = anim.tick();
    const after_second_interval = anim.current;

    try testing.expect(!after_first_interval.eql(after_second_interval));
}

test "Animator: zero frames returns false" {
    const Anim = Animator(2, 4);
    var anim = Anim{};
    try testing.expect(!anim.tick());
}

test "Animator: brightness scales output" {
    const F = Frame(1);
    const Anim = Animator(1, 4);
    var anim = Anim.fixed(F.solid(Color.white));
    anim.brightness = 128;
    anim.step_amount = 255;

    _ = anim.tick();
    try testing.expect(anim.current.pixels[0].r < 200);
    try testing.expect(anim.current.pixels[0].r > 50);
}

test "Animator: rotateAnim generates rotated frames" {
    const F = Frame(4);
    const Anim = Animator(4, 4);
    var f: F = .{};
    f.pixels[0] = Color.red;
    f.pixels[1] = Color.green;
    f.pixels[2] = Color.blue;
    f.pixels[3] = Color.white;

    const anim = Anim.rotateAnim(f, 8);
    try testing.expectEqual(@as(u8, 4), anim.total_frames);
    try testing.expectEqual(Color.green, anim.frames[1].pixels[0]);
    try testing.expectEqual(Color.blue, anim.frames[2].pixels[0]);
}
