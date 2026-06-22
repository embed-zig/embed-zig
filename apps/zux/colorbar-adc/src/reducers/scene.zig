pub fn make(comptime ZuxAppType: type) type {
    _ = ZuxAppType;

    return struct {
        const boot_source_id: u32 = 1;
        const keys_source_id: u32 = 2;

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
                    const click_count = switch (button.gesture) {
                        .click => |count| count,
                        else => return,
                    };
                    if (click_count == 0) return;

                    if (button.source_id == boot_source_id) {
                        setScene(stores, .split_7_colors);
                        return;
                    }
                    if (button.source_id == keys_source_id) {
                        const button_id = button.button_id orelse return;
                        switch (button_id) {
                            0 => setScene(stores, .red),
                            1 => setScene(stores, .orange),
                            2 => setScene(stores, .yellow),
                            3 => setScene(stores, .green),
                            4 => setScene(stores, .cyan),
                            5 => setScene(stores, .blue),
                            6 => setScene(stores, .violet),
                            else => return,
                        }
                    }
                },
                else => {},
            }
        }

        fn setScene(stores: anytype, scene_value: anytype) void {
            const SceneState = @TypeOf(stores.scene.running);
            stores.scene.invoke(scene_value, struct {
                fn apply(scene: *SceneState, next_scene: @TypeOf(scene_value)) void {
                    scene.current = next_scene;
                }
            }.apply);
        }
    };
}
