pub fn make(comptime ZuxAppType: type, comptime UiRuntime: type) type {
    return struct {
        const Self = @This();

        ui: *UiRuntime,

        pub fn init(ui: *UiRuntime) Self {
            return .{ .ui = ui };
        }

        pub fn render(self: *Self, app: *ZuxAppType.ImplType) !void {
            _ = app;
            try self.ui.requestRender();
        }
    };
}
