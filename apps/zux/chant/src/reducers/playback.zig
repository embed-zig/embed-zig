const glib = @import("glib");

pub const PlaybackProgress = struct {
    pub const event_name = "chant.playback_progress";

    allocator: glib.std.mem.Allocator,
    progress_pct: u8,

    pub fn init(allocator: glib.std.mem.Allocator, progress_pct: u8) !*@This() {
        const payload = try allocator.create(@This());
        payload.* = .{
            .allocator = allocator,
            .progress_pct = progress_pct,
        };
        return payload;
    }

    pub fn decodeJson(allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
        const object = switch (value) {
            .object => |object| object,
            else => return error.ExpectedObject,
        };
        const progress_field = object.get("progress_pct") orelse return error.MissingObjectField;
        const progress_pct: u8 = switch (progress_field) {
            .integer => |int_value| try castU8(int_value),
            else => return error.ExpectedInteger,
        };

        return init(allocator, progress_pct);
    }

    pub fn deinit(payload: *@This()) void {
        payload.allocator.destroy(payload);
    }

    fn castU8(value: i64) !u8 {
        if (value < 0) return error.IntegerOutOfRange;
        if (@as(u64, @intCast(value)) > glib.std.math.maxInt(u8)) return error.IntegerOutOfRange;
        return @intCast(value);
    }
};

pub fn registerCustomEvents(assembler: anytype) void {
    assembler.registerCustomEvent(PlaybackProgress);
}

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    _ = grt;
    const Stores = ZuxAppType.Store.Stores;
    const PlaybackState = @FieldType(Stores, "playback").StateType;

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
                .custom => |custom| {
                    if (custom.as(PlaybackProgress)) |progress| {
                        applyPlaybackProgress(stores, progress.progress_pct);
                        return true;
                    } else |_| {}
                },
                else => {},
            }
            return false;
        }

        fn applyPlaybackProgress(stores: *Stores, progress_pct: u8) void {
            const player = stores.player.get();
            if (!player.playing) return;

            const Context = struct {
                progress_pct: u8,
            };
            stores.playback.invoke(Context{ .progress_pct = progress_pct }, struct {
                fn invoke(playback: *PlaybackState, ctx: Context) void {
                    playback.progress_pct = ctx.progress_pct;
                }
            }.invoke);
        }
    };
}
