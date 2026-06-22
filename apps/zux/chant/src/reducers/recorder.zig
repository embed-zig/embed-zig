pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const AppImpl = ZuxAppType.ImplType;
    const Stores = ZuxAppType.Store.Stores;
    const PlayerState = @FieldType(Stores, "player").StateType;
    const log = grt.std.log.scoped(.chant_recorder);

    return struct {
        const Self = @This();

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
            _ = emit;

            switch (message.body) {
                .raw_single_button => |button| {
                    if (button.source_id != AppImpl.sourceId(.boot)) return false;
                    log.info("mic raw button pressed={}", .{button.pressed});
                    setRecording(stores, button.pressed);
                    return true;
                },
                else => return false,
            }
        }

        fn setRecording(stores: *Stores, recording: bool) void {
            const Context = struct {
                recording: bool,
            };
            stores.player.invoke(Context{ .recording = recording }, struct {
                fn invoke(player: *PlayerState, ctx: Context) void {
                    log.info("player.recording {} -> {}", .{ player.recording, ctx.recording });
                    player.recording = ctx.recording;
                }
            }.invoke);
        }
    };
}
