const lvgl = @import("../../../../lvgl.zig");

pub const Fixture = struct {
    display: lvgl.Display,

    pub fn init() !Fixture {
        lvgl.init();

        var display = lvgl.Display.create(320, 240) orelse {
            lvgl.deinit();
            return error.DisplayCreateFailed;
        };
        display.setDefault();

        return .{ .display = display };
    }

    pub fn deinit(self: *Fixture) void {
        var display = self.display;
        display.delete();
        lvgl.deinit();
    }

    pub fn screen(self: *Fixture) lvgl.Obj {
        return self.display.activeScreen();
    }
};
