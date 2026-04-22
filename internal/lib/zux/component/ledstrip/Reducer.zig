const stdz = @import("stdz");
const ledstrip = @import("ledstrip");
const Message = @import("../../pipeline/Message.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const state_mod = @import("State.zig");

pub fn make(comptime n: usize, comptime max_frames: usize, comptime tick_interval_ns: u64) type {
    comptime {
        if (max_frames == 0) {
            @compileError("zux.ledstrip.Reducer.make requires max_frames > 0");
        }
        if (tick_interval_ns == 0) {
            @compileError("zux.ledstrip.Reducer.make requires tick_interval_ns > 0");
        }
    }

    const state_type = state_mod.make(n, max_frames);
    const frame_type = ledstrip.Frame.make(n);

    return struct {
        pub const pixel_count = n;
        pub const frame_capacity = max_frames;

        pub const Color = ledstrip.Color;
        pub const Frame = frame_type;
        pub const FrameType = Frame;
        pub const State = state_type;

        pub fn reduce(store: anytype, message: Message, emit: Emitter) !usize {
            _ = emit;
            var next = currentState(store);
            const changed = reduceState(&next, message);
            store.set(next);
            return if (changed) 1 else 0;
        }

        pub fn reduceState(state: *State, message: Message) bool {
            switch (message.body) {
                .ledstrip_set => |event| {
                    const frame = frameFromPixels(event.pixels);
                    const target = frame.withBrightness(event.brightness);
                    resetPreservingCurrentControls(state);
                    state.frames[0] = frame;
                    state.total_frames = 1;
                    state.interval_ns = 0;
                    state.duration_ns = 0;
                    state.rest_started_seq = stdz.math.maxInt(u64);
                    state.brightness = event.brightness;

                    if (event.duration == 0) {
                        state.current = target;
                        state.step_amount = 255;
                        return true;
                    }

                    state.step_amount = computeStepAmount(state.current, target, event.duration);
                    return true;
                },
                .ledstrip_set_pixels => |event| {
                    const frame = frameFromPixels(event.pixels);
                    const target = frame.withBrightness(event.brightness);
                    resetPreservingCurrentControls(state);
                    state.frames[0] = frame;
                    state.total_frames = 1;
                    state.interval_ns = 0;
                    state.duration_ns = 0;
                    state.rest_started_seq = stdz.math.maxInt(u64);
                    state.brightness = event.brightness;
                    state.current = target;
                    state.step_amount = 255;
                    return true;
                },
                .ledstrip_flash => |event| {
                    resetPreservingCurrentControls(state);
                    state.frames[0] = frameFromPixels(event.pixels);
                    if (max_frames > 1) {
                        state.frames[1] = .{};
                        state.total_frames = 2;
                    } else {
                        state.total_frames = 1;
                    }
                    state.brightness = event.brightness;
                    state.interval_ns = event.interval_ns;
                    state.duration_ns = event.duration_ns;
                    state.rest_started_seq = stdz.math.maxInt(u64);
                    state.step_amount = computeStepAmount(
                        state.current,
                        targetForFrame(state, 0),
                        durationToTransitionTicks(event.duration_ns),
                    );
                    return true;
                },
                .ledstrip_pingpong => |event| {
                    resetPreservingCurrentControls(state);
                    state.frames[0] = frameFromPixels(event.from_pixels);
                    if (max_frames > 1) {
                        state.frames[1] = frameFromPixels(event.to_pixels);
                        state.total_frames = 2;
                    } else {
                        state.total_frames = 1;
                    }
                    state.brightness = event.brightness;
                    state.interval_ns = event.interval_ns;
                    state.duration_ns = event.duration_ns;
                    state.rest_started_seq = stdz.math.maxInt(u64);
                    state.step_amount = computeStepAmount(
                        state.current,
                        targetForFrame(state, 0),
                        durationToTransitionTicks(event.duration_ns),
                    );
                    return true;
                },
                .ledstrip_rotate => |event| {
                    resetPreservingCurrentControls(state);
                    const count = @min(n, max_frames);
                    if (count == 0) return false;

                    state.frames[0] = frameFromPixels(event.pixels);
                    for (1..count) |i| {
                        state.frames[i] = state.frames[i - 1].rotate();
                    }
                    state.total_frames = count;
                    state.brightness = event.brightness;
                    state.interval_ns = event.interval_ns;
                    state.duration_ns = event.duration_ns;
                    state.rest_started_seq = stdz.math.maxInt(u64);
                    state.step_amount = computeStepAmount(
                        state.current,
                        targetForFrame(state, 0),
                        durationToTransitionTicks(event.duration_ns),
                    );
                    return true;
                },
                .tick => |t| return tickState(state, t.seq),
                else => return false,
            }
        }

        pub fn tickState(state: *State, seq: u64) bool {
            if (state.total_frames == 0) return false;

            if (state.total_frames == 1) {
                const target = targetForFrame(state, 0);
                return ledstrip.Transition.stepFrame(n, &state.current, target, state.step_amount);
            }

            const target = targetForFrame(state, state.current_frame);
            const changed = ledstrip.Transition.stepFrame(n, &state.current, target, state.step_amount);

            if (changed) {
                state.rest_started_seq = stdz.math.maxInt(u64);
                return true;
            }

            const need = intervalHoldTicks(state.interval_ns);

            if (state.rest_started_seq == stdz.math.maxInt(u64)) {
                state.rest_started_seq = seq;
                if (need == 0) {
                    advanceToNextFrame(state);
                    return true;
                }
                return false;
            }

            if (seq - state.rest_started_seq >= need) {
                advanceToNextFrame(state);
                return true;
            }

            return false;
        }

        fn advanceToNextFrame(state: *State) void {
            state.rest_started_seq = stdz.math.maxInt(u64);
            state.current_frame = (state.current_frame + 1) % state.total_frames;
            state.step_amount = computeStepAmount(
                state.current,
                targetForFrame(state, state.current_frame),
                durationToTransitionTicks(state.duration_ns),
            );
        }

        fn resetPreservingCurrentControls(state: *State) void {
            const current = state.current;
            const brightness = state.brightness;
            const step_amount = state.step_amount;
            state.* = .{};
            state.current = current;
            state.brightness = brightness;
            state.step_amount = step_amount;
        }

        fn currentState(store: anytype) State {
            const StoreType = @TypeOf(store.*);
            if (@hasField(StoreType, "running") and @hasField(StoreType, "running_mu")) {
                store.running_mu.lock();
                defer store.running_mu.unlock();
                return store.running;
            }
            return store.get();
        }

        fn frameFromPixels(pixels: []const Color) FrameType {
            var frame: FrameType = .{};
            const count = @min(pixels.len, n);
            for (0..count) |i| {
                frame.pixels[i] = pixels[i];
            }
            return frame;
        }

        fn targetForFrame(state: *const State, frame_index: usize) FrameType {
            var target = state.frames[frame_index];
            if (state.brightness < 255) {
                target = target.withBrightness(state.brightness);
            }
            return target;
        }

        fn durationToTransitionTicks(duration_ns: u64) u32 {
            if (duration_ns == 0) return 1;
            const ticks = (duration_ns + tick_interval_ns - 1) / tick_interval_ns;
            return @max(1, @as(u32, @intCast(@min(ticks, @as(u64, stdz.math.maxInt(u32))))));
        }

        fn intervalHoldTicks(interval_ns: u64) u32 {
            if (interval_ns == 0) return 0;
            const ticks = (interval_ns + tick_interval_ns - 1) / tick_interval_ns;
            return @as(u32, @intCast(@min(ticks, @as(u64, stdz.math.maxInt(u32)))));
        }

        fn computeStepAmount(current: FrameType, target: FrameType, duration_ticks: u32) u8 {
            if (duration_ticks <= 1) return 255;

            const max_delta = frameMaxDelta(current, target);
            if (max_delta == 0) return 1;

            const step = @divFloor(@as(u32, max_delta) + duration_ticks - 1, duration_ticks);
            return @intCast(@max(@as(u32, 1), @min(step, 255)));
        }

        fn frameMaxDelta(current: FrameType, target: FrameType) u8 {
            var max_delta: u8 = 0;
            for (current.pixels, target.pixels) |cur, tgt| {
                max_delta = maxU8(max_delta, colorMaxDelta(cur, tgt));
            }
            return max_delta;
        }

        fn colorMaxDelta(a: Color, b: Color) u8 {
            return maxU8(channelDelta(a.r, b.r), maxU8(channelDelta(a.g, b.g), channelDelta(a.b, b.b)));
        }

        fn channelDelta(a: u8, b: u8) u8 {
            return if (a >= b) a - b else b - a;
        }

        fn maxU8(a: u8, b: u8) u8 {
            return if (a >= b) a else b;
        }
    };
}
