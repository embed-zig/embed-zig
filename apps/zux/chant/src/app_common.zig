const embed = @import("embed");
const glib = @import("glib");
const launcher = @import("launcher");
const zux = embed.zux;

const consts = @import("consts.zig");
const reducers_mod = @import("reducers.zig");
const renders_mod = @import("renders.zig");
const runtime_mod = @import("runtime.zig");

pub const TestPlatformCtx = struct {
    pub const AudioSystem = zux.spec.TestAudioSystem;
};

pub fn runtimeSpecType(comptime component_spec: []const u8) type {
    var builder = zux.spec.Builder.init();
    builder.addSpecSlices(&.{
        component_spec,
        @embedFile("spec/state.json"),
        @embedFile("spec/hooks.json"),
    });
    return builder.build();
}

pub fn specType(comptime component_spec: []const u8) type {
    var builder = zux.spec.Builder.init();
    builder.addSpecSlices(&.{
        component_spec,
        @embedFile("spec/state.json"),
        @embedFile("spec/hooks.json"),
        @embedFile("spec/user_stories/app_starts_with_track_state.json"),
        @embedFile("spec/user_stories/playing_play_pause_pauses.json"),
        @embedFile("spec/user_stories/paused_play_pause_resumes.json"),
        @embedFile("spec/user_stories/play_pause_pause_then_resume.json"),
        @embedFile("spec/user_stories/twinkle_next_selects_happy_birthday.json"),
        @embedFile("spec/user_stories/happy_birthday_next_selects_doll_bear.json"),
        @embedFile("spec/user_stories/doll_bear_next_wraps_twinkle.json"),
        @embedFile("spec/user_stories/next_resets_track_progress.json"),
        @embedFile("spec/user_stories/twinkle_previous_wraps_doll_bear.json"),
        @embedFile("spec/user_stories/previous_resets_track_progress.json"),
        @embedFile("spec/user_stories/doll_bear_previous_selects_happy_birthday.json"),
        @embedFile("spec/user_stories/happy_birthday_previous_selects_twinkle.json"),
        @embedFile("spec/user_stories/volume_up_increments.json"),
        @embedFile("spec/user_stories/grouped_controls_volume_up_increments.json"),
        @embedFile("spec/user_stories/volume_up_clamps_at_max.json"),
        @embedFile("spec/user_stories/volume_down_decrements.json"),
        @embedFile("spec/user_stories/grouped_controls_volume_down_decrements.json"),
        @embedFile("spec/user_stories/volume_down_clamps_at_min.json"),
        @embedFile("spec/user_stories/mic_press_starts_recording.json"),
        @embedFile("spec/user_stories/mic_release_stops_recording.json"),
        @embedFile("spec/user_stories/recording_play_pause_toggles_player.json"),
        @embedFile("spec/user_stories/recording_next_selects_next_track.json"),
        @embedFile("spec/user_stories/recording_previous_selects_previous_track.json"),
        @embedFile("spec/user_stories/recording_volume_up_increments.json"),
        @embedFile("spec/user_stories/recording_volume_down_decrements.json"),
        @embedFile("spec/user_stories/playback_progress_event_advances_state.json"),
        @embedFile("spec/user_stories/render_player_state_change_updates_display.json"),
        @embedFile("spec/user_stories/render_track_state_change_updates_display.json"),
    });
    return builder.build();
}

fn ZuxAppType(comptime component_spec: []const u8, comptime platform_ctx: type, comptime platform_grt: type) type {
    const SpecType = runtimeSpecType(component_spec);
    var spec = SpecType.init();
    var assembler = spec.assembler(platform_grt, .{});
    reducers_mod.registerCustomEvents(&assembler);
    const BuildConfig = assembler.BuildConfig();
    var build_config: BuildConfig = spec.defaultBuildConfig(BuildConfig);
    build_config.audio = *platform_ctx.AudioSystem;
    return assembler.build(build_config);
}

pub fn make(
    comptime component_spec: []const u8,
    comptime app_title: []const u8,
    comptime platform_ctx: type,
    comptime platform_grt: type,
) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = ZuxAppType(component_spec, platform_ctx, platform_grt);
        const Runtime = runtime_mod.make(platform_grt, ZuxApp);
        const Reducers = reducers_mod.make(platform_grt, ZuxApp, Runtime);
        const Renders = renders_mod.make(ZuxApp, Runtime);

        pub const title = app_title;
        pub const description = "Touch and mic driven Zux music player and recorder.";

        allocator: glib.std.mem.Allocator,
        zux_app: ZuxApp,
        reducers: Reducers = undefined,
        renders: Renders = undefined,
        runtime: Runtime = undefined,

        pub fn init(allocator: glib.std.mem.Allocator, base_config: ZuxApp.InitConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .zux_app = undefined,
                .reducers = Reducers.init(),
                .renders = Renders.init(),
            };

            var init_config = base_config;
            init_config.allocator = allocator;
            applyInitialState(&init_config);
            init_config.app_reducer = ZuxApp.ReducerHook.init(&self.reducers);
            init_config.app_sync = ZuxApp.RenderHook.init(&self.renders.control);
            init_config.app_render = ZuxApp.RenderHook.init(&self.renders.ui);

            self.zux_app = try ZuxApp.init(init_config);
            errdefer self.zux_app.deinit();

            self.runtime = try Runtime.init(.{
                .allocator = allocator,
                .zux_app = &self.zux_app,
                .player_task_options = playerRuntimeTaskOptions(),
                .recorder_task_options = recorderRuntimeTaskOptions(),
                .ui_config = .{
                    .task_options = uiRuntimeTaskOptions(),
                },
            });
            errdefer self.runtime.deinit();

            self.reducers.bindRuntime(&self.runtime);
            self.renders.bindRuntime(&self.runtime);
            try self.runtime.start();
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.runtime.deinit();
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            return testRunner(component_spec, platform_ctx, platform_grt);
        }

        fn applyInitialState(init_config: *ZuxApp.InitConfig) void {
            init_config.initial_state = .{
                .play_pause = .{},
                .boot = .{},
                .next = .{},
                .previous = .{},
                .volume_up = .{},
                .volume_down = .{},
                .controls = .{},
                .touch = .{},
                .audio = .{
                    .started = true,
                    .gain_db = consts.audio.default_gain_db,
                    .min_gain_db = consts.audio.minimum_gain_db,
                    .max_gain_db = consts.audio.maximum_gain_db,
                    .gain_step_db = consts.audio.gain_step_db,
                },
                .display = .{
                    .enabled = true,
                    .brightness = 255,
                },
                .player = .{
                    .playing = true,
                    .recording = false,
                    .selected = .twinkle,
                    .loop = true,
                },
                .playback = .{
                    .progress_pct = 0,
                },
            };
        }

        fn playerRuntimeTaskOptions() glib.task.Options {
            if (@hasDecl(platform_ctx, "chantPlayerTaskOptions")) {
                return platform_ctx.chantPlayerTaskOptions();
            }
            return .{ .min_stack_size = 16 * 1024 };
        }

        fn recorderRuntimeTaskOptions() glib.task.Options {
            if (@hasDecl(platform_ctx, "chantRecorderTaskOptions")) {
                return platform_ctx.chantRecorderTaskOptions();
            }
            return .{ .min_stack_size = 16 * 1024 };
        }

        fn uiRuntimeTaskOptions() glib.task.Options {
            if (@hasDecl(platform_ctx, "chantUiTaskOptions")) {
                return platform_ctx.chantUiTaskOptions();
            }
            return .{ .min_stack_size = 16 * 1024 };
        }
    });
}

pub fn testRunner(
    comptime component_spec: []const u8,
    comptime platform_ctx: type,
    comptime platform_grt: type,
) glib.testing.TestRunner {
    const SpecType = specType(component_spec);
    const ZuxApp = ZuxAppType(component_spec, platform_ctx, platform_grt);
    const Runtime = runtime_mod.make(platform_grt, ZuxApp);
    const Reducers = reducers_mod.make(platform_grt, ZuxApp, Runtime);
    const Renders = renders_mod.make(ZuxApp, Runtime);
    const UserStoryConfigFactoryImpl = struct {
        instance: Instance = undefined,

        pub const Instance = struct {
            init_config: ZuxApp.InitConfig,
            reducers: Reducers = undefined,
            renders: Renders = undefined,
            runtime: Runtime = undefined,
            runtime_initialized: bool = false,

            pub fn config(self_instance: *@This()) ZuxApp.InitConfig {
                return self_instance.init_config;
            }

            pub fn start(self_instance: *@This(), app: *ZuxApp) !void {
                self_instance.runtime = try Runtime.init(.{
                    .allocator = self_instance.init_config.allocator,
                    .zux_app = app,
                    .start_audio = false,
                });
                self_instance.runtime_initialized = true;
                self_instance.reducers.bindRuntime(&self_instance.runtime);
                self_instance.renders.bindRuntime(&self_instance.runtime);
                try self_instance.runtime.start();
            }

            pub fn deinit(self_instance: *@This()) void {
                if (self_instance.runtime_initialized) {
                    self_instance.runtime.deinit();
                    self_instance.runtime_initialized = false;
                }
            }
        };

        pub fn make(self_factory: *@This(), init_config: ZuxApp.InitConfig) !*Instance {
            self_factory.instance = .{
                .init_config = init_config,
                .reducers = Reducers.init(),
                .renders = Renders.init(),
            };
            self_factory.instance.init_config.app_reducer = ZuxApp.ReducerHook.init(&self_factory.instance.reducers);
            self_factory.instance.init_config.app_sync = ZuxApp.RenderHook.init(&self_factory.instance.renders.control);
            self_factory.instance.init_config.app_render = ZuxApp.RenderHook.init(&self_factory.instance.renders.ui);
            return &self_factory.instance;
        }
    };

    const spec = SpecType.init();
    return spec.testRunner(ZuxApp, UserStoryConfigFactoryImpl);
}

pub fn run(
    comptime component_spec: []const u8,
    comptime app_title: []const u8,
    comptime story_name: []const u8,
    comptime platform_ctx: type,
    comptime platform_grt: type,
) !void {
    const Launcher = make(component_spec, app_title, platform_ctx, platform_grt);

    try platform_ctx.setup();
    defer platform_ctx.teardown();

    var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_app);
    defer t.deinit();

    t.run(story_name, Launcher.createTestRunner());
    if (!t.wait()) return error.TestFailed;
}
