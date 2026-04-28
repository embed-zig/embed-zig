const binding = @import("binding.zig");
const Display = @import("Display.zig");
const Obj = @import("object/Obj.zig");

pub const Fixture = struct {
    display: Display,

    pub const InitError = error{DisplayCreateFailed};

    pub fn init() InitError!Fixture {
        binding.lv_init();

        var display = Display.create(320, 240) orelse {
            binding.lv_deinit();
            return error.DisplayCreateFailed;
        };
        display.setDefault();

        return .{ .display = display };
    }

    pub fn deinit(self: *Fixture) void {
        var display = self.display;
        display.delete();
        binding.lv_deinit();
    }

    pub fn screen(self: *Fixture) Obj {
        const handle = binding.lv_display_get_screen_active(self.display.raw()) orelse {
            @panic("LVGL display did not expose an active screen");
        };
        return Obj.fromRaw(handle);
    }
};
