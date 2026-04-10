//! ledstrip animator test runner — grouped contract checks for Animator.

const embed = @import("embed");
const testing_api = @import("testing");
const AnimatorMod = @import("../Animator.zig");
const Color = @import("../Color.zig");
const LedStrip = @import("../LedStrip.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    // Fake strip + Animator: no host threads; shallow call depth (~same class as embed fmt/json tests).
    return testing_api.TestRunner.fromFn(lib, 32 * 1024, struct {
        fn run(t: *testing_api.T, allocator: embed.mem.Allocator) !void {
            _ = t;
            try runAnimatorSuite(lib, allocator);
        }
    }.run);
}

pub fn run(comptime lib: type, allocator: lib.mem.Allocator) !void {
    try runAnimatorSuite(lib, allocator);
}

fn runAnimatorSuite(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const Suite = SuiteType(lib);
    try Suite.exec(allocator);
}

fn SuiteType(comptime lib: type) type {
    const testing = lib.testing;
    const Allocator = lib.mem.Allocator;
    const run_log = lib.log.scoped(.ledstrip_animator_runner);
    const max_fake_pixels = 8;

    const StripState = struct {
        pixel_count: usize = 0,
        refresh_calls: usize = 0,
        write_calls: usize = 0,
        pixels: [max_fake_pixels]Color = [_]Color{Color.black} ** max_fake_pixels,
    };

    const FakeImpl = struct {
        pub const Config = struct {
            allocator: Allocator,
            state: *StripState,
        };

        state: *StripState,

        pub fn init(config: Config) !@This() {
            _ = config.allocator;
            return .{ .state = config.state };
        }

        pub fn deinit(_: *@This()) void {}

        pub fn count(self: *@This()) usize {
            return self.state.pixel_count;
        }

        pub fn setPixel(self: *@This(), index: usize, color: Color) void {
            if (index >= self.state.pixel_count or index >= self.state.pixels.len) return;
            self.state.write_calls += 1;
            self.state.pixels[index] = color;
        }

        pub fn pixel(self: *@This(), index: usize) Color {
            if (index >= self.state.pixel_count or index >= self.state.pixels.len) return Color.black;
            return self.state.pixels[index];
        }

        pub fn refresh(self: *@This()) void {
            self.state.refresh_calls += 1;
        }
    };

    const FakeStrip = LedStrip.make(FakeImpl);

    return struct {
        fn exec(allocator: Allocator) !void {
            try runCase("render_equal_length_strip", allocator, testRenderEqualLengthStrip);
            try runCase("render_shorter_strip_truncates", allocator, testRenderShorterStripTruncates);
            try runCase("render_longer_strip_preserves_tail", allocator, testRenderLongerStripPreservesTail);
            try runCase("render_zero_count_strip_refreshes", allocator, testRenderZeroCountStripRefreshes);
            try runCase("render_zero_pixel_animator_refreshes", allocator, testRenderZeroPixelAnimatorRefreshes);
            try runCase("tick_without_frames_preserves_current", allocator, testTickWithoutFramesPreservesCurrent);
            try runCase("interval_zero_advances_every_tick", allocator, testIntervalZeroAdvancesEveryTick);
            try runCase("brightness_extremes_apply", allocator, testBrightnessExtremesApply);
            try runCase("flash_and_pingpong_degrade_at_capacity_one", allocator, testFlashAndPingpongDegradeAtCapacityOne);
            try runCase("rotate_anim_clamps_to_capacity", allocator, testRotateAnimClampsToCapacity);
            try runCase("step_amount_zero_does_not_converge", allocator, testStepAmountZeroDoesNotConverge);
        }

        fn runCase(
            comptime name: []const u8,
            allocator: Allocator,
            comptime case_fn: *const fn (Allocator) anyerror!void,
        ) !void {
            run_log.info("case={s}", .{name});
            try case_fn(allocator);
        }

        fn resetStripState(state: *StripState, pixel_count: usize, fill: Color) !void {
            try testing.expect(pixel_count <= state.pixels.len);
            state.* = .{ .pixel_count = pixel_count };
            @memset(&state.pixels, fill);
        }

        fn initStrip(allocator: Allocator, state: *StripState) !LedStrip {
            return try FakeStrip.init(.{
                .allocator = allocator,
                .state = state,
            });
        }

        fn expectPrefix(state: *const StripState, expected: []const Color) !void {
            for (expected, 0..) |color, index| {
                try testing.expectEqual(color, state.pixels[index]);
            }
        }

        fn testRenderEqualLengthStrip(allocator: Allocator) !void {
            const Anim = AnimatorMod.make(4, 4);
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

            var strip_state: StripState = undefined;
            try resetStripState(&strip_state, 4, Color.black);

            var strip = try initStrip(allocator, &strip_state);
            defer strip.deinit();

            Anim.render(strip, &anim_state);

            try testing.expectEqual(@as(usize, 4), strip_state.write_calls);
            try testing.expectEqual(@as(usize, 1), strip_state.refresh_calls);
            try expectPrefix(&strip_state, anim_state.current.pixels[0..]);
        }

        fn testRenderShorterStripTruncates(allocator: Allocator) !void {
            const Anim = AnimatorMod.make(4, 4);
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

            var strip_state: StripState = undefined;
            try resetStripState(&strip_state, 2, Color.black);

            var strip = try initStrip(allocator, &strip_state);
            defer strip.deinit();

            Anim.render(strip, &anim_state);

            try testing.expectEqual(@as(usize, 2), strip_state.write_calls);
            try testing.expectEqual(@as(usize, 1), strip_state.refresh_calls);
            try testing.expectEqual(Color.red, strip_state.pixels[0]);
            try testing.expectEqual(Color.green, strip_state.pixels[1]);
        }

        fn testRenderLongerStripPreservesTail(allocator: Allocator) !void {
            const Anim = AnimatorMod.make(4, 4);
            const tail_color = Color.rgb(7, 8, 9);
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

            var strip_state: StripState = undefined;
            try resetStripState(&strip_state, 6, tail_color);

            var strip = try initStrip(allocator, &strip_state);
            defer strip.deinit();

            Anim.render(strip, &anim_state);

            try testing.expectEqual(@as(usize, 4), strip_state.write_calls);
            try testing.expectEqual(@as(usize, 1), strip_state.refresh_calls);
            try expectPrefix(&strip_state, anim_state.current.pixels[0..]);
            try testing.expectEqual(tail_color, strip_state.pixels[4]);
            try testing.expectEqual(tail_color, strip_state.pixels[5]);
        }

        fn testRenderZeroCountStripRefreshes(allocator: Allocator) !void {
            const Anim = AnimatorMod.make(4, 4);
            const sentinel = Color.rgb(9, 9, 9);
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

            var strip_state: StripState = undefined;
            try resetStripState(&strip_state, 0, sentinel);

            var strip = try initStrip(allocator, &strip_state);
            defer strip.deinit();

            Anim.render(strip, &anim_state);

            try testing.expectEqual(@as(usize, 0), strip_state.write_calls);
            try testing.expectEqual(@as(usize, 1), strip_state.refresh_calls);
            try testing.expectEqual(sentinel, strip_state.pixels[0]);
            try testing.expectEqual(sentinel, strip_state.pixels[1]);
        }

        fn testRenderZeroPixelAnimatorRefreshes(allocator: Allocator) !void {
            const Anim = AnimatorMod.make(0, 4);
            const sentinel = Color.rgb(3, 4, 5);
            const anim_state = Anim.State{};

            var strip_state: StripState = undefined;
            try resetStripState(&strip_state, 3, sentinel);

            var strip = try initStrip(allocator, &strip_state);
            defer strip.deinit();

            Anim.render(strip, &anim_state);

            try testing.expectEqual(@as(usize, 0), strip_state.write_calls);
            try testing.expectEqual(@as(usize, 1), strip_state.refresh_calls);
            try testing.expectEqual(sentinel, strip_state.pixels[0]);
            try testing.expectEqual(sentinel, strip_state.pixels[1]);
            try testing.expectEqual(sentinel, strip_state.pixels[2]);
        }

        fn testTickWithoutFramesPreservesCurrent(_: Allocator) !void {
            const Anim = AnimatorMod.make(1, 4);
            const F = Anim.Frame;
            var state = Anim.State{
                .current = F.solid(Color.red),
            };

            try testing.expect(!Anim.tick(&state));
            try testing.expectEqual(Color.red, state.current.pixels[0]);
        }

        fn testIntervalZeroAdvancesEveryTick(_: Allocator) !void {
            const Anim = AnimatorMod.make(1, 4);
            const F = Anim.Frame;
            var state = Anim.State{};

            Anim.pingpong(&state, .{
                .from = F.solid(Color.red),
                .to = F.solid(Color.blue),
                .interval = 0,
            });
            state.step_amount = 255;

            try testing.expect(Anim.tick(&state));
            try testing.expectEqual(@as(usize, 1), state.current_frame);
            try testing.expectEqual(Color.blue, state.current.pixels[0]);

            try testing.expect(Anim.tick(&state));
            try testing.expectEqual(@as(usize, 0), state.current_frame);
            try testing.expectEqual(Color.red, state.current.pixels[0]);
        }

        fn testBrightnessExtremesApply(_: Allocator) !void {
            const Anim = AnimatorMod.make(1, 4);
            const F = Anim.Frame;

            var zero_state = Anim.State{};
            Anim.fixed(&zero_state, .{ .frame = F.solid(Color.white) });
            zero_state.brightness = 0;
            zero_state.step_amount = 255;

            try testing.expect(!Anim.tick(&zero_state));
            try testing.expectEqual(Color.black, zero_state.current.pixels[0]);

            var full_state = Anim.State{};
            Anim.fixed(&full_state, .{ .frame = F.solid(Color.red) });
            full_state.brightness = 255;
            full_state.step_amount = 255;

            try testing.expect(Anim.tick(&full_state));
            try testing.expectEqual(Color.red, full_state.current.pixels[0]);
        }

        fn testFlashAndPingpongDegradeAtCapacityOne(_: Allocator) !void {
            const Anim = AnimatorMod.make(1, 1);
            const F = Anim.Frame;
            var state = Anim.State{};

            Anim.flash(&state, .{
                .frame = F.solid(Color.blue),
                .interval = 3,
            });
            try testing.expectEqual(@as(usize, 1), state.total_frames);
            try testing.expectEqual(Color.blue, state.frames[0].pixels[0]);

            Anim.pingpong(&state, .{
                .from = F.solid(Color.red),
                .to = F.solid(Color.green),
                .interval = 4,
            });
            try testing.expectEqual(@as(usize, 1), state.total_frames);
            try testing.expectEqual(Color.red, state.frames[0].pixels[0]);
        }

        fn testRotateAnimClampsToCapacity(_: Allocator) !void {
            const Anim = AnimatorMod.make(4, 2);
            const F = Anim.Frame;
            const frame = F{
                .pixels = .{
                    Color.red,
                    Color.green,
                    Color.blue,
                    Color.white,
                },
            };
            var state = Anim.State{};

            Anim.rotateAnim(&state, .{
                .frame = frame,
                .interval = 1,
            });

            try testing.expectEqual(@as(usize, 2), state.total_frames);
            try testing.expect(state.frames[0].eql(frame));
            try testing.expect(state.frames[1].eql(frame.rotate()));
        }

        fn testStepAmountZeroDoesNotConverge(_: Allocator) !void {
            const Anim = AnimatorMod.make(1, 4);
            const F = Anim.Frame;
            var state = Anim.State{
                .current = F.solid(Color.black),
            };

            Anim.fixed(&state, .{ .frame = F.solid(Color.white) });
            state.step_amount = 0;

            try testing.expect(Anim.tick(&state));
            try testing.expectEqual(Color.black, state.current.pixels[0]);

            try testing.expect(Anim.tick(&state));
            try testing.expectEqual(Color.black, state.current.pixels[0]);
        }
    };
}
