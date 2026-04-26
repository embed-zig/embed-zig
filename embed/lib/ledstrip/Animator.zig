//! ledstrip.Animator — multi-frame strip animation helpers.

const glib = @import("glib");
const Color = @import("Color.zig");
const Frame = @import("Frame.zig");
const LedStrip = @import("LedStrip.zig");
const Transition = @import("Transition.zig");

pub fn make(comptime n: usize, comptime max_frames: usize) type {
    comptime {
        if (max_frames == 0) @compileError("Animator.make requires max_frames > 0");
    }

    const FrameType = Frame.make(n);

    return struct {
        pub const pixel_count = n;
        pub const frame_capacity = max_frames;
        pub const Frame = FrameType;
        pub const FixedArgs = struct {
            frame: FrameType,
        };
        pub const SetArgs = struct {
            frame: FrameType,
            brightness: u8 = 255,
            duration: u32 = 0,
        };
        pub const FlashArgs = struct {
            frame: FrameType,
            interval: u32,
        };
        pub const PingpongArgs = struct {
            from: FrameType,
            to: FrameType,
            interval: u32,
        };
        pub const RotateAnimArgs = struct {
            frame: FrameType,
            interval: u32,
        };

        pub const State = struct {
            frames: [max_frames]FrameType = [_]FrameType{.{}} ** max_frames,
            total_frames: usize = 0,
            current_frame: usize = 0,
            interval_ticks: u32 = 16,
            tick_count: u32 = 0,
            step_amount: u8 = 5,

            current: FrameType = .{},
            brightness: u8 = 255,
        };

        pub fn tick(state: *State) bool {
            if (state.total_frames == 0) return false;

            state.tick_count += 1;
            if (state.interval_ticks == 0 or state.tick_count >= state.interval_ticks) {
                state.tick_count = 0;
                state.current_frame = (state.current_frame + 1) % state.total_frames;
            }

            var target = state.frames[state.current_frame];
            if (state.brightness < 255) {
                target = target.withBrightness(state.brightness);
            }

            return Transition.stepFrame(n, &state.current, target, state.step_amount);
        }

        pub fn render(strip: LedStrip, state: *const State) void {
            strip.setPixels(0, state.current.pixels[0..]);
            strip.refresh();
        }

        pub fn fixed(state: *State, arg: FixedArgs) void {
            resetPreservingCurrentControls(state);
            state.frames[0] = arg.frame;
            state.total_frames = 1;
            state.interval_ticks = 16;
        }

        pub fn set(state: *State, arg: SetArgs) void {
            const target = arg.frame.withBrightness(arg.brightness);
            resetPreservingCurrentControls(state);
            state.frames[0] = arg.frame;
            state.total_frames = 1;
            state.interval_ticks = 16;
            state.brightness = arg.brightness;

            if (arg.duration == 0) {
                state.current = target;
                state.step_amount = 255;
                return;
            }

            state.step_amount = computeStepAmount(state.current, target, arg.duration);
        }

        pub fn flash(state: *State, arg: FlashArgs) void {
            resetPreservingCurrentControls(state);
            state.frames[0] = arg.frame;
            if (max_frames > 1) {
                state.frames[1] = .{};
                state.total_frames = 2;
            } else {
                state.total_frames = 1;
            }
            state.interval_ticks = arg.interval;
        }

        pub fn pingpong(state: *State, arg: PingpongArgs) void {
            resetPreservingCurrentControls(state);
            state.frames[0] = arg.from;
            if (max_frames > 1) {
                state.frames[1] = arg.to;
                state.total_frames = 2;
            } else {
                state.total_frames = 1;
            }
            state.interval_ticks = arg.interval;
        }

        pub fn rotateAnim(state: *State, arg: RotateAnimArgs) void {
            resetPreservingCurrentControls(state);
            const count = @min(n, max_frames);
            if (count == 0) return;

            state.frames[0] = arg.frame;
            for (1..count) |i| {
                state.frames[i] = state.frames[i - 1].rotate();
            }
            state.total_frames = count;
            state.interval_ticks = arg.interval;
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

        fn computeStepAmount(current: FrameType, target: FrameType, duration: u32) u8 {
            if (duration <= 1) return 255;

            const max_delta = frameMaxDelta(current, target);
            if (max_delta == 0) return 1;

            const step = @divFloor(@as(u32, max_delta) + duration - 1, duration);
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn fixedConvergesToTarget() !void {
            const F = Frame.make(4);
            const Anim = make(4, 4);
            var state = Anim.State{};
            Anim.fixed(&state, .{ .frame = F.solid(Color.red) });
            state.step_amount = 50;

            var ticks: u32 = 0;
            while (!state.current.eql(F.solid(Color.red))) : (ticks += 1) {
                _ = Anim.tick(&state);
                if (ticks > 100) break;
            }

            try grt.std.testing.expect(state.current.eql(F.solid(Color.red)));
        }

        fn flashAlternatesFrames() !void {
            const F = Frame.make(1);
            const Anim = make(1, 4);
            var state = Anim.State{};
            Anim.flash(&state, .{
                .frame = F.solid(Color.white),
                .interval = 2,
            });
            state.step_amount = 255;

            _ = Anim.tick(&state);
            _ = Anim.tick(&state);
            const after_first_interval = state.current;

            _ = Anim.tick(&state);
            _ = Anim.tick(&state);
            const after_second_interval = state.current;

            try grt.std.testing.expect(!after_first_interval.eql(after_second_interval));
        }

        fn zeroFramesReturnsFalse() !void {
            const Anim = make(2, 4);
            var state = Anim.State{};

            try grt.std.testing.expect(!Anim.tick(&state));
        }

        fn brightnessScalesOutput() !void {
            const F = Frame.make(1);
            const Anim = make(1, 4);
            var state = Anim.State{};
            Anim.fixed(&state, .{ .frame = F.solid(Color.white) });
            state.brightness = 128;
            state.step_amount = 255;

            _ = Anim.tick(&state);
            try grt.std.testing.expect(state.current.pixels[0].r < 200);
            try grt.std.testing.expect(state.current.pixels[0].r > 50);
        }

        fn rotateAnimGeneratesRotatedFrames() !void {
            const F = Frame.make(4);
            const Anim = make(4, 4);
            var frame: F = .{};
            frame.pixels[0] = Color.red;
            frame.pixels[1] = Color.green;
            frame.pixels[2] = Color.blue;
            frame.pixels[3] = Color.white;

            var state = Anim.State{};
            Anim.rotateAnim(&state, .{
                .frame = frame,
                .interval = 8,
            });
            try grt.std.testing.expectEqual(@as(usize, 4), state.total_frames);
            try grt.std.testing.expectEqual(Color.green, state.frames[1].pixels[0]);
            try grt.std.testing.expectEqual(Color.blue, state.frames[2].pixels[0]);
        }

        fn pingpongUsesTwoTargetFrames() !void {
            const F = Frame.make(1);
            const Anim = make(1, 4);
            var state = Anim.State{};
            Anim.pingpong(&state, .{
                .from = F.solid(Color.red),
                .to = F.solid(Color.blue),
                .interval = 3,
            });

            try grt.std.testing.expectEqual(@as(usize, 2), state.total_frames);
            try grt.std.testing.expectEqual(Color.red, state.frames[0].pixels[0]);
            try grt.std.testing.expectEqual(Color.blue, state.frames[1].pixels[0]);
        }

        fn patternMutatorsPreserveBrightnessAndStepAmount() !void {
            const F = Frame.make(1);
            const Anim = make(1, 4);
            var state = Anim.State{
                .brightness = 123,
                .step_amount = 17,
                .current = F.solid(Color.red),
            };

            Anim.flash(&state, .{
                .frame = F.solid(Color.blue),
                .interval = 3,
            });
            try grt.std.testing.expectEqual(@as(u8, 123), state.brightness);
            try grt.std.testing.expectEqual(@as(u8, 17), state.step_amount);

            Anim.fixed(&state, .{ .frame = F.solid(Color.green) });
            try grt.std.testing.expectEqual(@as(u8, 123), state.brightness);
            try grt.std.testing.expectEqual(@as(u8, 17), state.step_amount);

            Anim.pingpong(&state, .{
                .from = F.solid(Color.white),
                .to = F.solid(Color.black),
                .interval = 4,
            });
            try grt.std.testing.expectEqual(@as(u8, 123), state.brightness);
            try grt.std.testing.expectEqual(@as(u8, 17), state.step_amount);
        }

        fn setPreservesCurrentAndUsesDuration() !void {
            const F = Frame.make(1);
            const Anim = make(1, 4);
            var state = Anim.State{
                .current = F.solid(Color.black),
            };

            Anim.set(&state, .{
                .frame = F.solid(Color.white),
                .brightness = 128,
                .duration = 2,
            });

            try grt.std.testing.expectEqual(Color.black, state.current.pixels[0]);
            try grt.std.testing.expectEqual(@as(u8, 64), state.step_amount);

            _ = Anim.tick(&state);
            try grt.std.testing.expectEqual(Color.rgb(64, 64, 64), state.current.pixels[0]);

            _ = Anim.tick(&state);
            try grt.std.testing.expectEqual(Color.rgb(128, 128, 128), state.current.pixels[0]);
        }

        fn setWithZeroDurationSnapsImmediately() !void {
            const F = Frame.make(1);
            const Anim = make(1, 4);
            var state = Anim.State{
                .current = F.solid(Color.red),
            };

            Anim.set(&state, .{
                .frame = F.solid(Color.blue),
                .brightness = 255,
                .duration = 0,
            });

            try grt.std.testing.expectEqual(Color.blue, state.current.pixels[0]);
            try grt.std.testing.expectEqual(@as(u8, 255), state.step_amount);
        }

        fn renderFlushesCurrentFrameToStrip(allocator: glib.std.mem.Allocator) !void {
            const StateData = struct {
                refresh_calls: usize = 0,
                pixels: [4]Color = [_]Color{Color.black} ** 4,
            };

            const Impl = struct {
                pub const Config = struct {
                    allocator: glib.std.mem.Allocator,
                    state: *StateData,
                };

                state: *StateData,

                pub fn init(config: Config) !@This() {
                    return .{ .state = config.state };
                }

                pub fn deinit(_: *@This()) void {}

                pub fn count(_: *@This()) usize {
                    return 4;
                }

                pub fn setPixel(self: *@This(), index: usize, color: Color) void {
                    if (index >= self.state.pixels.len) return;
                    self.state.pixels[index] = color;
                }

                pub fn pixel(self: *@This(), index: usize) Color {
                    if (index >= self.state.pixels.len) return Color.black;
                    return self.state.pixels[index];
                }

                pub fn refresh(self: *@This()) void {
                    self.state.refresh_calls += 1;
                }
            };

            const Anim = make(4, 4);
            const anim_state = Anim.State{
                .current = .{
                    .pixels = .{
                        Color.red,
                        Color.green,
                        Color.blue,
                        Color.white,
                    },
                },
            };

            var strip_state = StateData{};
            var strip = try LedStrip.make(Impl).init(.{
                .allocator = allocator,
                .state = &strip_state,
            });
            defer strip.deinit();

            Anim.render(strip, &anim_state);

            try grt.std.testing.expectEqual(@as(usize, 1), strip_state.refresh_calls);
            try grt.std.testing.expectEqual(Color.red, strip.pixel(0));
            try grt.std.testing.expectEqual(Color.green, strip.pixel(1));
            try grt.std.testing.expectEqual(Color.blue, strip.pixel(2));
            try grt.std.testing.expectEqual(Color.white, strip.pixel(3));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.fixedConvergesToTarget() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.flashAlternatesFrames() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.zeroFramesReturnsFalse() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.brightnessScalesOutput() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rotateAnimGeneratesRotatedFrames() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.pingpongUsesTwoTargetFrames() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.patternMutatorsPreserveBrightnessAndStepAmount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.setPreservesCurrentAndUsesDuration() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.setWithZeroDurationSnapsImmediately() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.renderFlushesCurrentFrameToStrip(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
