pub fn make(comptime ZuxAppType: type) type {
    _ = ZuxAppType;

    return struct {
        const keys_source_id: u32 = 2;
        const no_button_id: u32 = 999;

        pub fn reduce(
            self: *@This(),
            stores: anytype,
            message: anytype,
            emit: anytype,
        ) !void {
            _ = self;
            _ = emit;

            switch (message.body) {
                .raw_grouped_button => |button| {
                    if (button.source_id != keys_source_id) return;
                    updateRaw(stores, button.button_id, button.pressed);
                },
                .button_gesture => |button| {
                    if (button.source_id != keys_source_id) return;
                    switch (button.gesture) {
                        .click => |count| updateGesture(stores, button.button_id, count),
                        else => {},
                    }
                },
                else => {},
            }
        }

        fn updateRaw(stores: anytype, button_id: ?u32, pressed: bool) void {
            const State = @TypeOf(stores.debug.running);
            const Patch = struct {
                button_id: ?u32,
                pressed: bool,
            };
            stores.debug.invoke(Patch{ .button_id = button_id, .pressed = pressed }, struct {
                fn apply(debug: *State, patch: Patch) void {
                    debug.raw_id = patch.button_id orelse no_button_id;
                    debug.raw_pressed = patch.pressed;
                    debug.raw_events += 1;
                }
            }.apply);
        }

        fn updateGesture(stores: anytype, button_id: ?u32, click_count: u32) void {
            const State = @TypeOf(stores.debug.running);
            const Patch = struct {
                button_id: ?u32,
                click_count: u32,
            };
            stores.debug.invoke(Patch{ .button_id = button_id, .click_count = click_count }, struct {
                fn apply(debug: *State, patch: Patch) void {
                    debug.gesture_id = patch.button_id orelse no_button_id;
                    debug.click_count = patch.click_count;
                    debug.gesture_events += 1;
                }
            }.apply);
        }
    };
}
