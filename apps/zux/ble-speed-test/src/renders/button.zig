const glib = @import("glib");

const speed_test = @import("../reducers/speed_test.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    return struct {
        const Self = @This();
        const log = grt.std.log.scoped(.ble_speed_button);

        allocator: glib.std.mem.Allocator,
        zux_app: *ZuxAppType,
        last_pressed_at: ?glib.time.instant.Time = null,

        pub fn init(allocator: glib.std.mem.Allocator, zux_app: *ZuxAppType) Self {
            return .{
                .allocator = allocator,
                .zux_app = zux_app,
            };
        }

        pub fn render(self: *Self, app: *ZuxAppType.ImplType) !void {
            _ = app;

            const button = self.zux_app.store.stores.boot.get();
            const gesture_kind = button.gesture_kind orelse return;
            if (gesture_kind != .click) return;
            if (button.click_count == 0) return;
            if (self.last_pressed_at == button.pressed_at) return;

            self.last_pressed_at = button.pressed_at;
            try self.dispatchReset();
        }

        fn dispatchReset(self: *Self) !void {
            const payload = try speed_test.ActionEvent.init(self.allocator, .reset);
            errdefer payload.deinit();
            const custom = self.zux_app.initCustomEvent(
                speed_test.ActionEvent,
                speed_test.source_id,
                payload,
            );
            _ = try self.zux_app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .custom = custom },
            });
            log.info("button reset stats", .{});
        }
    };
}
