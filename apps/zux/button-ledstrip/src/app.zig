const embed = @import("embed");
const glib = @import("glib");
const launcher = @import("launcher");
const zux = embed.zux;

const scene_hooks = @import("hooks/scene.zig");

pub const SpecType = blk: {
    var builder = zux.spec.Builder.init();
    builder.addSpecSlices(&.{
        @embedFile("spec/component.json"),
        @embedFile("spec/state.json"),
        @embedFile("spec/hooks.json"),
        @embedFile("spec/user_stories/red_click_targets_blue.json"),
        @embedFile("spec/user_stories/red_idle_keeps_target_red.json"),
        @embedFile("spec/user_stories/red_click_does_not_target_other_colors.json"),
        @embedFile("spec/user_stories/blue_click_targets_green.json"),
        @embedFile("spec/user_stories/blue_idle_keeps_target_blue.json"),
        @embedFile("spec/user_stories/blue_click_does_not_target_other_colors.json"),
        @embedFile("spec/user_stories/green_click_targets_yellow.json"),
        @embedFile("spec/user_stories/green_idle_keeps_target_green.json"),
        @embedFile("spec/user_stories/green_click_does_not_target_other_colors.json"),
        @embedFile("spec/user_stories/yellow_click_targets_red.json"),
        @embedFile("spec/user_stories/yellow_idle_keeps_target_yellow.json"),
        @embedFile("spec/user_stories/yellow_click_does_not_target_other_colors.json"),
        @embedFile("spec/user_stories/white_click_targets_red.json"),
        @embedFile("spec/user_stories/white_idle_keeps_target_white.json"),
        @embedFile("spec/user_stories/short_click_changes_target_only.json"),
        @embedFile("spec/user_stories/short_click_does_not_jump_visible_color.json"),
        @embedFile("spec/user_stories/pending_color_click_uses_current_target.json"),
        @embedFile("spec/user_stories/rapid_two_clicks_advance_two_targets.json"),
        @embedFile("spec/user_stories/off_short_click_keeps_off.json"),
        @embedFile("spec/user_stories/off_idle_ticks_keep_off.json"),
        @embedFile("spec/user_stories/on_hold_3s_turns_off.json"),
        @embedFile("spec/user_stories/on_states_hold_3s_turn_off.json"),
        @embedFile("spec/user_stories/on_hold_less_than_3s_keeps_on.json"),
        @embedFile("spec/user_stories/on_short_click_does_not_turn_off.json"),
        @embedFile("spec/user_stories/on_hold_exactly_3s_turns_off.json"),
        @embedFile("spec/user_stories/on_hold_between_3s_and_5s_turns_off_not_marquee.json"),
        @embedFile("spec/user_stories/off_hold_3s_turns_white.json"),
        @embedFile("spec/user_stories/off_hold_less_than_3s_keeps_off.json"),
        @embedFile("spec/user_stories/off_hold_exactly_3s_turns_white.json"),
        @embedFile("spec/user_stories/off_hold_between_3s_and_5s_turns_white_not_marquee.json"),
        @embedFile("spec/user_stories/any_hold_5s_enters_marquee.json"),
        @embedFile("spec/user_stories/hold_less_than_5s_not_marquee.json"),
        @embedFile("spec/user_stories/hold_exactly_5s_enters_marquee.json"),
        @embedFile("spec/user_stories/on_hold_5s_off_then_marquee.json"),
        @embedFile("spec/user_stories/off_hold_5s_white_then_marquee.json"),
        @embedFile("spec/user_stories/hold_5s_overrides_3s_state.json"),
        @embedFile("spec/user_stories/hold_5s_does_not_remain_at_3s_state.json"),
        @embedFile("spec/user_stories/hold_3s_fires_once_during_same_press.json"),
        @embedFile("spec/user_stories/hold_between_3s_and_5s_keeps_3s_state_without_flicker.json"),
        @embedFile("spec/user_stories/color_lerps_on_tick.json"),
        @embedFile("spec/user_stories/color_lerp_first_tick_has_midpoint.json"),
        @embedFile("spec/user_stories/color_lerp_second_tick_has_next_midpoint.json"),
        @embedFile("spec/user_stories/color_lerp_monotonic_toward_target.json"),
        @embedFile("spec/user_stories/color_lerp_does_not_emit_target_on_first_tick.json"),
        @embedFile("spec/user_stories/color_lerp_render_outputs_midpoint_to_strip.json"),
        @embedFile("spec/user_stories/color_lerp_render_does_not_skip_midpoint.json"),
        @embedFile("spec/user_stories/color_lerp_reaches_target_after_finite_ticks.json"),
        @embedFile("spec/user_stories/color_does_not_lerp_without_tick.json"),
        @embedFile("spec/user_stories/color_does_not_jump_before_threshold.json"),
        @embedFile("spec/user_stories/color_stable_when_target_reached.json"),
        @embedFile("spec/user_stories/marquee_starts_with_red_target.json"),
        @embedFile("spec/user_stories/marquee_short_click_keeps_marquee.json"),
        @embedFile("spec/user_stories/marquee_tick_lerps_to_target.json"),
        @embedFile("spec/user_stories/marquee_lerp_first_tick_has_midpoint.json"),
        @embedFile("spec/user_stories/marquee_lerp_render_outputs_midpoint_to_strip.json"),
        @embedFile("spec/user_stories/marquee_lerp_does_not_skip_to_target.json"),
        @embedFile("spec/user_stories/marquee_wait_less_than_10ms_no_lerp.json"),
        @embedFile("spec/user_stories/marquee_close_to_red_targets_green.json"),
        @embedFile("spec/user_stories/marquee_close_to_green_targets_blue.json"),
        @embedFile("spec/user_stories/marquee_close_to_blue_targets_red.json"),
        @embedFile("spec/user_stories/marquee_not_close_keeps_target.json"),
        @embedFile("spec/user_stories/marquee_reaches_target_finitely.json"),
        @embedFile("spec/user_stories/marquee_no_infinite_convergence.json"),
    });
    break :blk builder.build();
};

pub fn make(comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = assemble(platform_grt);
        pub const desktop = .{
            .title = "button-ledstrip",
            .description = "Single Power button driving a Zux LED strip user story.",
        };

        allocator: glib.std.mem.Allocator,
        zux_app: ZuxApp,
        scene: scene_hooks.Scene = .{},

        pub fn init(allocator: glib.std.mem.Allocator, base_config: ZuxApp.InitConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .zux_app = undefined,
            };

            var init_config = base_config;
            init_config.allocator = allocator;
            init_config.initial_state = .{
                .button = .{},
                .strip = .{},
                .scene = .{
                    .mode = .off,
                    .target_color_name = .none,
                    .target_color = 0,
                    .visible_color = 0,
                    .transitioning = false,
                    .marquee_stage = .none,
                },
            };
            init_config.scene_reducer = ZuxApp.ReducerHook.init(&self.scene);
            init_config.scene_render = ZuxApp.RenderHook.init(&self.scene);

            self.zux_app = try ZuxApp.init(init_config);
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            const UserStoryConfigFactoryImpl = struct {
                instance: Instance = undefined,

                pub const Instance = struct {
                    init_config: ZuxApp.InitConfig,
                    scene: scene_hooks.Scene = .{},

                    pub fn config(self_instance: *@This()) ZuxApp.InitConfig {
                        return self_instance.init_config;
                    }

                    pub fn deinit(self_instance: *@This()) void {
                        _ = self_instance;
                    }
                };

                pub fn make(self_factory: *@This(), init_config: ZuxApp.InitConfig) !*Instance {
                    self_factory.instance = .{ .init_config = init_config };
                    self_factory.instance.init_config.scene_reducer = ZuxApp.ReducerHook.init(&self_factory.instance.scene);
                    self_factory.instance.init_config.scene_render = ZuxApp.RenderHook.init(&self_factory.instance.scene);
                    return &self_factory.instance;
                }
            };

            const spec = SpecType.init();
            return spec.testRunner(ZuxApp, UserStoryConfigFactoryImpl);
        }
    });
}

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    const Launcher = make(platform_grt);

    try platform_ctx.setup();
    defer platform_ctx.teardown();

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_app);
    defer t.deinit();

    t.run("button-ledstrip/stories", Launcher.createTestRunner());
    if (!t.wait()) return error.TestFailed;
}

fn assemble(comptime platform_grt: type) type {
    const assembler_config: zux.AssemblerConfig = .{};
    return comptime blk: {
        var spec = SpecType.init();
        break :blk spec.buildApp(platform_grt, assembler_config);
    };
}
