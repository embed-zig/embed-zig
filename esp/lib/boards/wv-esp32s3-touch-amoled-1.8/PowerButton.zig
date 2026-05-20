const binding = @import("bindings/common.zig");

const PowerButton = @This();

pub fn isPressed(self: *PowerButton) !bool {
    _ = self;
    return binding.wv_power_button_pressed();
}
