const scene_mod = @import("renders/scene.zig");

pub fn make(comptime ZuxAppType: type, comptime RuntimeType: type) type {
    const Scene = scene_mod.make(ZuxAppType, RuntimeType);

    return struct {
        const Self = @This();

        scene: Scene,

        pub fn init() Self {
            return .{
                .scene = Scene.init(),
            };
        }

        pub fn bindRuntime(self: *Self, runtime: *RuntimeType) void {
            self.scene.bindRuntime(runtime);
        }
    };
}
