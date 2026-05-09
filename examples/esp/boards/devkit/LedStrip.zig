const embed = @import("embed");
const binding = @import("bindings/led_strip.zig");

const LedStrip = @This();

pixel_value: embed.ledstrip.Color = embed.ledstrip.Color.black,

pub fn handle(self: *LedStrip) embed.ledstrip.LedStrip {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn count(_: *LedStrip) usize {
    return 1;
}

fn setPixel(self: *LedStrip, index: usize, color: embed.ledstrip.Color) void {
    if (index != 0) return;
    self.pixel_value = color;
}

fn pixel(self: *LedStrip, index: usize) embed.ledstrip.Color {
    if (index != 0) return embed.ledstrip.Color.black;
    return self.pixel_value;
}

fn refresh(self: *LedStrip) void {
    _ = binding.devkit_led_strip_set_rgb(
        self.pixel_value.r,
        self.pixel_value.g,
        self.pixel_value.b,
    );
}

const vtable = embed.ledstrip.LedStrip.VTable{
    .deinit = struct {
        fn call(_: *anyopaque) void {}
    }.call,
    .count = struct {
        fn call(ptr: *anyopaque) usize {
            const self: *LedStrip = @ptrCast(@alignCast(ptr));
            return self.count();
        }
    }.call,
    .setPixel = struct {
        fn call(ptr: *anyopaque, index: usize, color: embed.ledstrip.Color) void {
            const self: *LedStrip = @ptrCast(@alignCast(ptr));
            self.setPixel(index, color);
        }
    }.call,
    .pixel = struct {
        fn call(ptr: *anyopaque, index: usize) embed.ledstrip.Color {
            const self: *LedStrip = @ptrCast(@alignCast(ptr));
            return self.pixel(index);
        }
    }.call,
    .refresh = struct {
        fn call(ptr: *anyopaque) void {
            const self: *LedStrip = @ptrCast(@alignCast(ptr));
            self.refresh();
        }
    }.call,
};
