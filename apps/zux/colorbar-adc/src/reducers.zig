const scene_mod = @import("reducers/scene.zig");

pub fn make(comptime ZuxAppType: type) type {
    const Scene = scene_mod.make(ZuxAppType);

    return struct {
        const Self = @This();

        scene: Scene = .{},

        pub fn init() Self {
            return .{};
        }

        pub fn reduce(
            self: *Self,
            stores: *ZuxAppType.Store.Stores,
            message: ZuxAppType.Message,
            emit: ZuxAppType.Emitter,
        ) !void {
            try self.scene.reduce(stores, message, emit);
        }
    };
}
