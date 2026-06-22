const glib = @import("glib");

const ui_mod = @import("runtime/ui.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const Ui = ui_mod.make(grt, ZuxAppType);

    return struct {
        const Runtime = @This();

        pub const Config = struct {
            allocator: glib.std.mem.Allocator,
            zux_app: *ZuxAppType,
            ui_config: Ui.Config = .{},
        };

        ui: Ui,

        pub fn init(config: Config) !Runtime {
            return .{
                .ui = try Ui.init(config.allocator, config.zux_app, config.ui_config),
            };
        }

        pub fn start(self: *Runtime) !void {
            try self.ui.start();
        }

        pub fn deinit(self: *Runtime) void {
            self.ui.deinit();
            self.* = undefined;
        }
    };
}
