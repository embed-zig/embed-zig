const debug_mod = @import("reducers/debug.zig");

pub fn make(comptime ZuxAppType: type) type {
    const Debug = debug_mod.make(ZuxAppType);

    return struct {
        const Self = @This();

        debug: Debug = .{},

        pub fn init() Self {
            return .{};
        }

        pub fn reduce(
            self: *Self,
            stores: *ZuxAppType.Store.Stores,
            message: ZuxAppType.Message,
            emit: ZuxAppType.Emitter,
        ) !void {
            try self.debug.reduce(stores, message, emit);
        }
    };
}
