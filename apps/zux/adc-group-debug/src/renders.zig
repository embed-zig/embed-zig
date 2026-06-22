const debug_mod = @import("renders/debug.zig");

pub fn make(comptime ZuxAppType: type, comptime RuntimeType: type) type {
    const Debug = debug_mod.make(ZuxAppType, RuntimeType);

    return struct {
        const Self = @This();

        debug: Debug,

        pub fn init() Self {
            return .{
                .debug = Debug.init(),
            };
        }

        pub fn bindRuntime(self: *Self, runtime: *RuntimeType) void {
            self.debug.bindRuntime(runtime);
        }
    };
}
