pub fn make(comptime ZuxAppType: type, comptime UiRuntime: type) type {
    return struct {
        const Self = @This();

        ui: ?*UiRuntime,

        pub fn init(ui: ?*UiRuntime) Self {
            return .{ .ui = ui };
        }

        pub fn setRuntime(self: *Self, ui: *UiRuntime) void {
            self.ui = ui;
        }

        pub fn render(self: *Self, app: *ZuxAppType.ImplType) !void {
            _ = app;
            const ui = self.ui orelse return;
            try ui.requestRender();
        }
    };
}
