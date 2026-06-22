const audio_mod = @import("reducers/audio.zig");
const playback_mod = @import("reducers/playback.zig");
const player_mod = @import("reducers/player.zig");
const recorder_mod = @import("reducers/recorder.zig");

pub const playback = playback_mod;

pub fn registerCustomEvents(assembler: anytype) void {
    playback.registerCustomEvents(assembler);
}

pub fn make(comptime grt: type, comptime ZuxAppType: type, comptime RuntimeType: type) type {
    const Audio = audio_mod.make(grt, ZuxAppType);
    const Playback = playback.make(grt, ZuxAppType);
    const Player = player_mod.make(grt, ZuxAppType);
    const Recorder = recorder_mod.make(grt, ZuxAppType);

    return struct {
        const Self = @This();

        audio: Audio,
        playback: Playback,
        player: Player,
        recorder: Recorder,
        runtime: ?*RuntimeType = null,

        pub fn init() Self {
            return .{
                .audio = Audio.init(),
                .playback = Playback.init(),
                .player = Player.init(),
                .recorder = Recorder.init(),
            };
        }

        pub fn bindRuntime(self: *Self, runtime: *RuntimeType) void {
            self.runtime = runtime;
        }

        pub fn reduce(
            self: *Self,
            stores: *ZuxAppType.Store.Stores,
            message: ZuxAppType.Message,
            emit: ZuxAppType.Emitter,
        ) !void {
            if (self.runtime) |runtime| {
                try runtime.reduceUiInput(stores, message, emit);
            }
            if (try self.player.reduce(stores, message, emit)) return;
            if (try self.recorder.reduce(stores, message, emit)) return;
            if (try self.audio.reduce(stores, message, emit)) return;
            if (try self.playback.reduce(stores, message, emit)) return;
            try emit.emit(message);
        }
    };
}
