const glib = @import("glib");
const ledstrip = @import("ledstrip");

pub fn make(comptime n: usize, comptime max_frames: usize) type {
    comptime {
        if (max_frames == 0) {
            @compileError("zux.ledstrip.State.make requires max_frames > 0");
        }
    }

    const frame_type = ledstrip.Frame.make(n);

    return struct {
        pub const pixel_count = n;
        pub const frame_capacity = max_frames;

        pub const Color = ledstrip.Color;
        pub const Frame = frame_type;
        pub const FrameType = Frame;

        frames: [max_frames]FrameType = [_]FrameType{.{}} ** max_frames,
        total_frames: usize = 0,
        current_frame: usize = 0,
        /// Wall-clock hold between keyframes for multi-frame modes.
        interval: glib.time.duration.Duration = 0,
        /// Cross-fade duration toward each keyframe for multi-frame modes.
        duration: glib.time.duration.Duration = 0,
        /// `Pipeline` tick sequence when the strip became stationary at `current_frame`
        /// (`glib.std.math.maxInt(u64)` while transitioning).
        rest_started_seq: u64 = glib.std.math.maxInt(u64),
        step_amount: u8 = 5,

        current: FrameType = .{},
        brightness: u8 = 255,
    };
}
