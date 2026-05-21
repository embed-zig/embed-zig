const drivers = @import("drivers");

const TestDisplay = @This();

pub const State = struct {
    enabled: bool = false,
    brightness: u8 = 0,
    set_enabled_count: usize = 0,
    set_brightness_count: usize = 0,
    rendered: bool = false,
    draws: usize = 0,
    last_x: u16 = 0,
    last_y: u16 = 0,
    last_w: u16 = 0,
    last_h: u16 = 0,
    non_black_pixels: usize = 0,
};

state: State = .{},

pub fn reset(self: *TestDisplay) void {
    self.state = .{};
}

pub fn api(self: *TestDisplay) drivers.Display {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn deinitFn(_: *anyopaque) void {}

fn widthFn(_: *anyopaque) u16 {
    return 96;
}

fn heightFn(_: *anyopaque) u16 {
    return 64;
}

fn setEnabledFn(ptr: *anyopaque, enabled: bool) drivers.Display.Error!void {
    const self: *TestDisplay = @ptrCast(@alignCast(ptr));
    self.state.enabled = enabled;
    self.state.set_enabled_count += 1;
}

fn enabledFn(ptr: *anyopaque) drivers.Display.Error!bool {
    const self: *TestDisplay = @ptrCast(@alignCast(ptr));
    return self.state.enabled;
}

fn setBrightnessFn(ptr: *anyopaque, brightness: u8) drivers.Display.Error!void {
    const self: *TestDisplay = @ptrCast(@alignCast(ptr));
    self.state.brightness = brightness;
    self.state.set_brightness_count += 1;
}

fn brightnessFn(ptr: *anyopaque) drivers.Display.Error!u8 {
    const self: *TestDisplay = @ptrCast(@alignCast(ptr));
    return self.state.brightness;
}

fn drawBitmapFn(
    ptr: *anyopaque,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const drivers.Display.Rgb,
) drivers.Display.Error!void {
    const self: *TestDisplay = @ptrCast(@alignCast(ptr));
    self.state.rendered = true;
    self.state.draws += 1;
    self.state.last_x = x;
    self.state.last_y = y;
    self.state.last_w = w;
    self.state.last_h = h;
    self.state.non_black_pixels = 0;
    for (pixels[0 .. @as(usize, w) * @as(usize, h)]) |pixel| {
        if (pixel.r != 0 or pixel.g != 0 or pixel.b != 0) {
            self.state.non_black_pixels += 1;
        }
    }
}

const vtable = drivers.Display.VTable{
    .deinit = deinitFn,
    .width = widthFn,
    .height = heightFn,
    .setEnabled = setEnabledFn,
    .enabled = enabledFn,
    .setBrightness = setBrightnessFn,
    .brightness = brightnessFn,
    .drawBitmap = drawBitmapFn,
};
