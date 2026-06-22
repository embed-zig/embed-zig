pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    _ = grt;
    const controls = @import("../controls.zig");
    const AppImpl = ZuxAppType.ImplType;
    const Stores = ZuxAppType.Store.Stores;
    const PlayerState = @FieldType(Stores, "player").StateType;
    const PlaybackState = @FieldType(Stores, "playback").StateType;

    return struct {
        const Self = @This();
        const PlayerAction = enum {
            play_pause,
            next,
            previous,
        };

        pub fn init() Self {
            return .{};
        }

        pub fn reduce(
            self: *Self,
            stores: *Stores,
            message: ZuxAppType.Message,
            emit: ZuxAppType.Emitter,
        ) !bool {
            _ = self;

            const button = switch (message.body) {
                .button_gesture => |button| button,
                else => return false,
            };
            const count = switch (button.gesture) {
                .click => |count| count,
                .long_press => return true,
            };
            if (count == 0) return true;

            switch (playerAction(button) orelse return false) {
                .play_pause => try togglePlaying(
                    stores,
                    emit,
                    AppImpl.sourceId(.audio),
                    message.timestamp,
                ),
                .next => selectNextTrack(stores),
                .previous => selectPreviousTrack(stores),
            }
            return true;
        }

        fn playerAction(button: anytype) ?PlayerAction {
            switch (button.source_id) {
                AppImpl.sourceId(.play_pause) => return .play_pause,
                AppImpl.sourceId(.next) => return .next,
                AppImpl.sourceId(.previous) => return .previous,
                AppImpl.sourceId(.controls) => switch (controls.fromButtonId(button.button_id) orelse return null) {
                    .front => return .play_pause,
                    .next => return .next,
                    .previous => return .previous,
                    else => return null,
                },
                else => return null,
            }
        }

        fn togglePlaying(
            stores: *Stores,
            emit: ZuxAppType.Emitter,
            audio_source_id: u32,
            timestamp: @FieldType(ZuxAppType.Message, "timestamp"),
        ) !void {
            var next_playing = false;
            const Context = struct {
                next_playing: *bool,
            };

            stores.player.invoke(Context{ .next_playing = &next_playing }, struct {
                fn invoke(player: *PlayerState, ctx: Context) void {
                    player.playing = !player.playing;
                    ctx.next_playing.* = player.playing;
                }
            }.invoke);
            try emitAudioStarted(emit, audio_source_id, timestamp, next_playing);
        }

        fn selectNextTrack(stores: *Stores) void {
            stores.player.invoke({}, struct {
                fn invoke(player: *PlayerState, _: void) void {
                    player.selected = switch (player.selected) {
                        .twinkle => .happy_birthday,
                        .happy_birthday => .doll_bear,
                        .doll_bear => if (player.loop) .twinkle else .doll_bear,
                    };
                }
            }.invoke);
            resetPlaybackProgress(stores);
        }

        fn selectPreviousTrack(stores: *Stores) void {
            stores.player.invoke({}, struct {
                fn invoke(player: *PlayerState, _: void) void {
                    player.selected = switch (player.selected) {
                        .twinkle => if (player.loop) .doll_bear else .twinkle,
                        .happy_birthday => .twinkle,
                        .doll_bear => .happy_birthday,
                    };
                }
            }.invoke);
            resetPlaybackProgress(stores);
        }

        fn resetPlaybackProgress(stores: *Stores) void {
            stores.playback.invoke({}, struct {
                fn invoke(playback: *PlaybackState, _: void) void {
                    playback.progress_pct = 0;
                }
            }.invoke);
        }

        fn emitAudioStarted(
            emit: ZuxAppType.Emitter,
            source_id: u32,
            timestamp: @FieldType(ZuxAppType.Message, "timestamp"),
            started: bool,
        ) !void {
            try emit.emit(.{
                .origin = .manual,
                .timestamp = timestamp,
                .body = if (started) .{
                    .audio_system_start = .{
                        .source_id = source_id,
                    },
                } else .{
                    .audio_system_stop = .{
                        .source_id = source_id,
                    },
                },
            });
        }
    };
}
