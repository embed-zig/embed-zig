const control_mod = @import("renders/control.zig");
const ui_mod = @import("renders/ui.zig");

pub fn make(comptime ZuxAppType: type, comptime RuntimeType: type) type {
    const Control = control_mod.make(ZuxAppType, RuntimeType);
    const Ui = ui_mod.make(ZuxAppType, RuntimeType);

    return struct {
        const Self = @This();

        control: Control,
        ui: Ui,

        pub fn init() Self {
            return .{
                .control = Control.init(),
                .ui = Ui.init(),
            };
        }

        pub fn bindRuntime(self: *Self, runtime: *RuntimeType) void {
            self.control.bindRuntime(runtime);
            self.ui.bindRuntime(runtime);
        }
    };
}
