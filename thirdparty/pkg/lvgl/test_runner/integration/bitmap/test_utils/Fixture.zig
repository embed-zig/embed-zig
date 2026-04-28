const std = @import("std");
const display_api = @import("embed").drivers;
const lvgl = @import("../../../../../lvgl.zig");

const Display = display_api.Display;

pub const width: u16 = 64;
pub const height: u16 = 32;
pub const Color565 = u16;

const Bridge = struct {
    output: *Display,
    flush_error: ?Display.Error = null,
    scratch: [width * height]Display.Rgb = undefined,
};

output: *Display,
width_px: u16,
height_px: u16,
display: lvgl.Display,
bridge: Bridge,
framebuffer: [width * height]Color565 = [_]Color565{0} ** (width * height),

pub const InitError = error{DisplayCreateFailed};

pub fn init(output: *Display) InitError!@This() {
    lvgl.init();

    const width_px = @min(width, output.width());
    const height_px = @min(height, output.height());
    const display = lvgl.Display.create(width_px, height_px) orelse {
        lvgl.deinit();
        return error.DisplayCreateFailed;
    };

    var self = @This(){
        .output = output,
        .width_px = width_px,
        .height_px = height_px,
        .display = display,
        .bridge = .{ .output = output },
    };
    self.display.setDefault();
    self.connect();
    return self;
}

pub fn deinit(self: *@This()) void {
    var display = self.display;
    display.delete();
    lvgl.deinit();
}

pub fn screen(self: *@This()) lvgl.Obj {
    return self.display.activeScreen();
}

pub fn render(self: *@This()) Display.Error!void {
    self.bridge.flush_error = null;
    lvgl.binding.lv_refr_now(self.display.raw());
    if (self.bridge.flush_error) |err| return err;
}

fn connect(self: *@This()) void {
    lvgl.binding.lv_display_set_color_format(self.display.raw(), lvgl.binding.LV_COLOR_FORMAT_RGB565);
    lvgl.binding.lv_display_set_buffers(
        self.display.raw(),
        &self.framebuffer,
        null,
        @sizeOf(@TypeOf(self.framebuffer)),
        lvgl.binding.LV_DISPLAY_RENDER_MODE_FULL,
    );
    lvgl.binding.lv_display_set_user_data(self.display.raw(), &self.bridge);
    lvgl.binding.lv_display_set_flush_cb(self.display.raw(), flushCb);
}

fn flushCb(
    disp: ?*lvgl.binding.Display,
    area: ?*const lvgl.binding.Area,
    px_map: ?[*]u8,
) callconv(.c) void {
    const display = disp orelse return;
    const draw_area = area orelse return;
    const pixels_ptr = px_map orelse return;
    const bridge_ptr = lvgl.binding.lv_display_get_user_data(display) orelse return;
    const bridge: *Bridge = @ptrCast(@alignCast(bridge_ptr));

    const w: u16 = @intCast(lvgl.binding.lv_area_get_width(draw_area));
    const h: u16 = @intCast(lvgl.binding.lv_area_get_height(draw_area));
    const pixel_count = @as(usize, w) * @as(usize, h);
    const bytes = @as([*]const u8, @ptrCast(pixels_ptr))[0 .. pixel_count * @sizeOf(Color565)];
    const pixels = std.mem.bytesAsSlice(Color565, bytes);
    const x: u16 = @intCast(draw_area.x1);
    const y: u16 = @intCast(draw_area.y1);

    for (pixels, 0..) |pixel, idx| {
        bridge.scratch[idx] = Display.Rgb.from565(pixel);
    }

    bridge.output.drawBitmap(x, y, w, h, bridge.scratch[0..pixel_count]) catch |err| {
        bridge.flush_error = err;
    };
    lvgl.binding.lv_display_flush_ready(display);
}
