const glib = @import("glib");

const drivers = @import("drivers");
const switch_component = @import("../../component/switch.zig");
const Message = @import("../../pipeline/Message.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn switchReducerTracksEnabledState() !void {
            var state = switch_component.state.Switch{};
            const message = Message{
                .body = .{ .switch_set = .{ .source_id = 1, .enabled = true } },
            };

            try grt.std.testing.expect(switch_component.Reducer.reduceSwitchState(&state, message));
            try grt.std.testing.expect(state.enabled);
            try grt.std.testing.expect(!switch_component.Reducer.reduceSwitchState(&state, message));
        }

        fn switchRenderAppliesOutputState() !void {
            const Impl = struct {
                enabled: bool = false,

                pub fn set(self: *@This(), enabled: bool) drivers.Switch.Error!void {
                    self.enabled = enabled;
                }
            };

            var impl = Impl{};
            const sw = drivers.Switch.init(&impl);
            try switch_component.Render.renderSwitch(.{ .enabled = true }, sw);
            try grt.std.testing.expect(impl.enabled);
        }

        fn pwmReducerTracksOutputState() !void {
            var state = switch_component.state.Pwm{};
            const duty = drivers.Pwm.Duty.init(1, 2);
            const message = Message{
                .body = .{ .pwm_set = .{
                    .source_id = 2,
                    .enabled = true,
                    .frequency_hz = 2000,
                    .duty = duty,
                } },
            };

            try grt.std.testing.expect(switch_component.Reducer.reducePwmState(&state, message));
            try grt.std.testing.expect(state.enabled);
            try grt.std.testing.expectEqual(@as(u32, 2000), state.frequency_hz);
            try grt.std.testing.expectEqual(@as(u32, 1), state.duty.numerator);
            try grt.std.testing.expectEqual(@as(u32, 2), state.duty.denominator);
            try grt.std.testing.expect(!switch_component.Reducer.reducePwmState(&state, message));
        }

        fn pwmRenderAppliesSignalState() !void {
            const Impl = struct {
                hz: u32 = 0,
                duty: drivers.Pwm.Duty = .zero,
                enabled: bool = false,

                pub fn setFrequencyHz(self: *@This(), hz: u32) drivers.Pwm.Error!void {
                    self.hz = hz;
                }

                pub fn setDuty(self: *@This(), duty: drivers.Pwm.Duty) drivers.Pwm.Error!void {
                    self.duty = duty;
                }

                pub fn enable(self: *@This()) drivers.Pwm.Error!void {
                    self.enabled = true;
                }

                pub fn disable(self: *@This()) drivers.Pwm.Error!void {
                    self.enabled = false;
                }
            };

            var impl = Impl{};
            const pwm = drivers.Pwm.init(&impl);
            try switch_component.Render.renderPwm(.{
                .enabled = true,
                .frequency_hz = 400,
                .duty = drivers.Pwm.Duty.init(3, 4),
            }, pwm);

            try grt.std.testing.expectEqual(@as(u32, 400), impl.hz);
            try grt.std.testing.expectEqual(@as(u32, 3), impl.duty.numerator);
            try grt.std.testing.expectEqual(@as(u32, 4), impl.duty.denominator);
            try grt.std.testing.expect(impl.enabled);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            inline for (.{
                TestCase.switchReducerTracksEnabledState,
                TestCase.switchRenderAppliesOutputState,
                TestCase.pwmReducerTracksOutputState,
                TestCase.pwmRenderAppliesSignalState,
            }) |case| {
                case() catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
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
