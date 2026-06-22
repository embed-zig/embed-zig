const speed_test_mod = @import("reducers/speed_test.zig");

pub const speed_test = speed_test_mod;

pub fn registerCustomEvents(assembler: anytype) void {
    speed_test.registerCustomEvents(assembler);
}

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const SpeedTest = speed_test.make(grt, ZuxAppType);

    return struct {
        const Self = @This();

        speed_test: SpeedTest,

        pub fn init() Self {
            return .{
                .speed_test = SpeedTest.init(),
            };
        }

        pub fn reduce(
            self: *Self,
            stores: *ZuxAppType.Store.Stores,
            message: ZuxAppType.Message,
            emit: ZuxAppType.Emitter,
        ) !void {
            try self.speed_test.reduce(stores, message, emit);
        }
    };
}
