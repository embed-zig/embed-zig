pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const controls = @import("../controls.zig");
    const AppImpl = ZuxAppType.ImplType;
    const Stores = ZuxAppType.Store.Stores;
    const log = grt.std.log.scoped(.chant_audio_reducer);

    return struct {
        const Self = @This();
        const GainAction = enum(u8) {
            none = 0,
            inc = 1,
            dec = 2,
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
                .long_press => return false,
            };
            if (count == 0) return true;

            const mapped = controls.fromButtonId(button.button_id);
            const action = gainAction(button, mapped);
            if (action == .none) return false;
            const audio = stores.audio.get();
            log.info("volume gesture source_id={} controls_src={} vu_src={} vd_src={} button_id={?} mapped={s} clicks={} action={s} gain={} step={}", .{
                button.source_id,
                AppImpl.sourceId(.controls),
                AppImpl.sourceId(.volume_up),
                AppImpl.sourceId(.volume_down),
                button.button_id,
                controlName(mapped),
                count,
                gainActionName(action),
                audio.gain_db,
                audio.gain_step_db,
            });

            switch (action) {
                .none => unreachable,
                .inc => try emitAudioGainStep(
                    emit,
                    AppImpl.sourceId(.audio),
                    message.timestamp,
                    .inc,
                ),
                .dec => try emitAudioGainStep(
                    emit,
                    AppImpl.sourceId(.audio),
                    message.timestamp,
                    .dec,
                ),
            }
            return true;
        }

        fn gainAction(button: anytype, mapped: ?controls.Id) GainAction {
            switch (button.source_id) {
                AppImpl.sourceId(.volume_up) => return .inc,
                AppImpl.sourceId(.volume_down) => return .dec,
                AppImpl.sourceId(.controls) => switch (mapped orelse return .none) {
                    .volume_up => return .inc,
                    .volume_down => return .dec,
                    else => return .none,
                },
                else => return .none,
            }
        }

        fn controlName(action: ?controls.Id) []const u8 {
            return switch (action orelse return "none") {
                .up => "up",
                .previous => "previous",
                .next => "next",
                .down => "down",
                .volume_up => "volume_up",
                .volume_down => "volume_down",
                .front => "front",
            };
        }

        fn gainActionName(action: GainAction) []const u8 {
            return switch (action) {
                .none => "none",
                .inc => "inc",
                .dec => "dec",
            };
        }

        fn emitAudioGainStep(
            emit: ZuxAppType.Emitter,
            source_id: u32,
            timestamp: @FieldType(ZuxAppType.Message, "timestamp"),
            comptime direction: enum { inc, dec },
        ) !void {
            if (direction == .inc) {
                log.info("emit audio_system_inc_gain source_id={}", .{source_id});
                try emit.emit(.{
                    .origin = .manual,
                    .timestamp = timestamp,
                    .body = .{
                        .audio_system_inc_gain = .{
                            .source_id = source_id,
                        },
                    },
                });
                return;
            }

            log.info("emit audio_system_dec_gain source_id={}", .{source_id});
            try emit.emit(.{
                .origin = .manual,
                .timestamp = timestamp,
                .body = .{
                    .audio_system_dec_gain = .{
                        .source_id = source_id,
                    },
                },
            });
        }
    };
}
