const embed = @import("embed");
const glib = @import("glib");
const zux = embed.zux;

const scene_hooks = @import("hooks/scene.zig");

pub const SpecType = blk: {
    var builder = zux.spec.Builder.init();
    builder.addSpecSlices(&.{
        @embedFile("spec/component.json"),
        @embedFile("spec/state.json"),
        @embedFile("spec/hooks.json"),
        @embedFile("spec/user_stories/fiftieth_tick_starts_rainbow.json"),
        @embedFile("spec/user_stories/initial_tick_keeps_strip_off.json"),
        @embedFile("spec/user_stories/new_sequence_resets_to_red.json"),
        @embedFile("spec/user_stories/rainbow_first_tick_initializes_schedule.json"),
        @embedFile("spec/user_stories/rainbow_later_tick_wraps_palette.json"),
        @embedFile("spec/user_stories/rainbow_tick_advances_palette.json"),
        @embedFile("spec/user_stories/second_tick_selects_green.json"),
        @embedFile("spec/user_stories/third_tick_selects_blue.json"),
        @embedFile("spec/user_stories/thirtieth_tick_turns_strip_off.json"),
        @embedFile("spec/user_stories/unsupported_tick_keeps_current_color.json"),
    });
    break :blk builder.build();
};

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    const config: zux.AssemblerConfig = .{};
    const AppType = comptime blk: {
        var spec = SpecType.init();
        spec.setReducer("scene_reducer", scene_hooks.sceneReducer);
        spec.setRender("scene_render", scene_hooks.renderScene);
        break :blk spec.buildApp(platform_grt, config);
    };

    try platform_ctx.setup();
    defer platform_ctx.teardown();

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_app);
    defer t.deinit();

    const InitConfigFactory = struct {
        fn make(init_config: AppType.InitConfig) AppType.InitConfig {
            return init_config;
        }
    };
    const spec = SpecType.init();
    const story_runner = spec.testRunner(AppType, InitConfigFactory.make);

    t.run("button-ledstrip/stories", story_runner);
    if (!t.wait()) return error.TestFailed;
}
