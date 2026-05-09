const binding = @import("bindings/power_button.zig");

const PowerButton = @This();

pub fn isPressed(self: *PowerButton) !bool {
    _ = self;
    return binding.devkit_power_button_pressed();
}
