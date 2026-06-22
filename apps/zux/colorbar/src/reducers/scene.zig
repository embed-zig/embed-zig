const consts = @import("../consts.zig");

pub const Scene = struct {
    pub fn reduce(
        self: *@This(),
        stores: anytype,
        message: anytype,
        emit: anytype,
    ) !void {
        _ = self;
        _ = emit;

        switch (message.body) {
            .button_gesture => |button| {
                if (button.gesture != .click) return;
                const SceneState = @TypeOf(stores.scene.running);
                stores.scene.invoke({}, struct {
                    fn apply(scene: *SceneState, _: void) void {
                        scene.current = consts.nextScene(scene.current);
                    }
                }.apply);
            },
            else => {},
        }
    }
};
