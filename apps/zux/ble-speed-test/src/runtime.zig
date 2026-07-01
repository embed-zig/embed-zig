const ble_mod = @import("runtime/ble.zig");
const glib = @import("glib");
const ui_mod = @import("runtime/ui.zig");

const consts = @import("consts.zig");

pub fn make(
    comptime grt: type,
    comptime ZuxAppType: type,
    comptime role: consts.Role,
    comptime transport: consts.Transport,
) type {
    const Ble = ble_mod.make(grt, ZuxAppType, role, transport);
    const UiRuntime = ui_mod.make(grt, ZuxAppType);

    return struct {
        const Self = @This();
        pub const Ui = UiRuntime;

        ble: Ble,
        ui: UiRuntime,

        pub const InitConfig = struct {
            allocator: grt.std.mem.Allocator,
            zux_app: *ZuxAppType,
            bt: @import("embed").bt.Host,
            ble_task_options: glib.task.Options,
            ui_config: UiRuntime.Config = .{},
        };

        pub fn init(config: InitConfig) !Self {
            return .{
                .ble = try Ble.init(config.allocator, config.bt, config.zux_app, config.ble_task_options),
                .ui = try Ui.init(config.allocator, config.zux_app, config.ui_config),
            };
        }

        pub fn start(self: *Self) !void {
            try self.ui.start();
            errdefer self.ui.deinit();
            try self.ble.start();
        }

        pub fn deinit(self: *Self) void {
            self.ble.stop();
            self.ui.deinit();
            self.* = undefined;
        }
    };
}
