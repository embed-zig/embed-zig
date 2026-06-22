const glib = @import("glib");

const button_mod = @import("renders/button.zig");
const ui_mod = @import("renders/ui.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type, comptime UiRuntime: type) type {
    const Button = button_mod.make(grt, ZuxAppType);
    const Ui = ui_mod.make(ZuxAppType, UiRuntime);

    return struct {
        const Self = @This();

        button: Button,
        ui: Ui,

        pub const InitConfig = struct {
            allocator: glib.std.mem.Allocator,
            zux_app: *ZuxAppType,
            ui_runtime: *UiRuntime,
        };

        pub fn init(config: InitConfig) Self {
            return .{
                .button = Button.init(config.allocator, config.zux_app),
                .ui = Ui.init(config.ui_runtime),
            };
        }
    };
}
