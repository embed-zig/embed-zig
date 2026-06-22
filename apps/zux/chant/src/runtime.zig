const glib = @import("glib");
const player_mod = @import("runtime/player.zig");
const recorder_mod = @import("runtime/recorder.zig");
const ui_mod = @import("runtime/ui.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const AudioSystemPtr = ZuxAppType.AudioSystem(.audio);
    const AudioSystem = switch (@typeInfo(AudioSystemPtr)) {
        .pointer => |info| if (info.size == .one)
            info.child
        else
            @compileError("chant audio component must be a single-item pointer"),
        else => @compileError("chant audio component must be a single-item pointer"),
    };
    const Player = player_mod.make(grt, ZuxAppType, AudioSystem);
    const Recorder = recorder_mod.make(grt, ZuxAppType, AudioSystem);
    const Ui = ui_mod.make(grt, ZuxAppType);
    const log = grt.std.log.scoped(.chant_runtime);

    return struct {
        const Self = @This();
        pub const UiRuntime = Ui;

        player: Player,
        recorder: Recorder,
        ui: Ui,
        start_audio: bool,
        last_sync_recording: ?bool = null,
        last_sync_playing: ?bool = null,
        last_sync_gain_db: ?i8 = null,

        pub const InitConfig = struct {
            allocator: grt.std.mem.Allocator,
            zux_app: *ZuxAppType,
            player_task_options: glib.task.Options = .{
                .min_stack_size = 16 * 1024,
            },
            recorder_task_options: glib.task.Options = .{
                .min_stack_size = 16 * 1024,
            },
            ui_config: Ui.Config = .{},
            start_audio: bool = true,
        };

        pub fn init(config: InitConfig) !Self {
            return .{
                .player = try Player.init(config.allocator, config.zux_app, config.player_task_options),
                .recorder = try Recorder.init(config.allocator, config.zux_app, config.recorder_task_options),
                .ui = try Ui.init(config.allocator, config.zux_app, config.ui_config),
                .start_audio = config.start_audio,
            };
        }

        pub fn start(self: *Self) !void {
            try self.ui.start();
            errdefer self.ui.deinit();
            if (!self.start_audio) return;

            try self.player.start();
            errdefer self.player.deinit();
            try self.recorder.start();
            self.syncAudio();
        }

        pub fn syncAudio(self: *Self) void {
            const player_state = self.player.zux_app.store.stores.player.get();
            const audio_state = self.player.zux_app.store.stores.audio.get();
            if (self.last_sync_recording == null or
                self.last_sync_recording.? != player_state.recording or
                self.last_sync_playing == null or
                self.last_sync_playing.? != player_state.playing)
            {
                log.info("sync audio recording={} playing={}", .{ player_state.recording, player_state.playing });
                self.last_sync_recording = player_state.recording;
                self.last_sync_playing = player_state.playing;
            }
            if (self.last_sync_gain_db == null or self.last_sync_gain_db.? != audio_state.gain_db) {
                log.info("sync gain old={?} new={} step={} min={} max={}", .{
                    self.last_sync_gain_db,
                    audio_state.gain_db,
                    audio_state.gain_step_db,
                    audio_state.min_gain_db,
                    audio_state.max_gain_db,
                });
                self.last_sync_gain_db = audio_state.gain_db;
            }
            if (!self.start_audio) return;
            self.player.notifySync();
            self.recorder.notifySync();
        }

        pub fn requestRender(self: *Self) !void {
            try self.ui.requestRender();
        }

        pub fn reduceUiInput(self: *Self, stores: anytype, message: anytype, emit: anytype) !void {
            try self.ui.reduce(stores, message, emit);
        }

        pub fn deinit(self: *Self) void {
            self.recorder.deinit();
            self.player.deinit();
            self.ui.deinit();
            self.* = undefined;
        }
    };
}
