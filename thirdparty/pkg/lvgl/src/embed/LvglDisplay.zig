const embed_pkg = @import("embed");
const glib = @import("glib");

const binding = @import("../binding.zig");
const Display = @import("../Display.zig");

const LvglDisplay = @This();
const DisplayApi = embed_pkg.drivers.Display;

pub const Rgb888ByteOrder = enum {
    rgb,
    bgr,
};

pub const Config = struct {
    display: DisplayApi,
    /// LVGL stores this buffer by reference; keep it alive until `deinit`.
    draw_buffer: []u8,
    /// Temporary RGB conversion storage; must cover the largest flush area.
    flush_buffer: []DisplayApi.Rgb,
    render_mode: binding.DisplayRenderMode = binding.LV_DISPLAY_RENDER_MODE_PARTIAL,
    color_format: binding.ColorFormat = binding.LV_COLOR_FORMAT_RGB888,
    rgb888_byte_order: Rgb888ByteOrder = .bgr,
    set_default: bool = true,
};

display: DisplayApi = undefined,
lv_display: ?Display = null,
draw_buffer: []u8 = &.{},
flush_buffer: []DisplayApi.Rgb = &.{},
color_format: binding.ColorFormat = binding.LV_COLOR_FORMAT_RGB888,
rgb888_byte_order: Rgb888ByteOrder = .bgr,

pub fn init(self: *LvglDisplay, config: Config) !void {
    if (self.lv_display != null) return error.AlreadyInitialized;
    if (config.draw_buffer.len == 0 or config.flush_buffer.len == 0) return error.InvalidBuffer;

    var lv_display = Display.create(config.display.width(), config.display.height()) orelse return error.OutOfMemory;
    errdefer lv_display.delete();

    lv_display.setUserData(self);
    lv_display.setColorFormat(config.color_format);
    lv_display.setBuffers(
        @ptrCast(config.draw_buffer.ptr),
        null,
        @intCast(config.draw_buffer.len),
        config.render_mode,
    );
    lv_display.setFlushCb(flushCb);
    if (config.set_default) {
        lv_display.setDefault();
    }

    self.* = .{
        .display = config.display,
        .lv_display = lv_display,
        .draw_buffer = config.draw_buffer,
        .flush_buffer = config.flush_buffer,
        .color_format = config.color_format,
        .rgb888_byte_order = config.rgb888_byte_order,
    };
}

pub fn deinit(self: *LvglDisplay) void {
    if (self.lv_display) |*lv_display| {
        lv_display.setUserData(null);
        lv_display.delete();
    }
    self.lv_display = null;
}

pub fn handle(self: *LvglDisplay) Display {
    return self.lv_display orelse @panic("lvgl.embed.LvglDisplay is not initialized");
}

pub fn raw(self: *LvglDisplay) *binding.Display {
    return self.handle().raw();
}

pub fn setDisplay(self: *LvglDisplay, display: DisplayApi) void {
    self.display = display;
}

fn flush(self: *LvglDisplay, area: *const binding.Area, px_map: *const u8) void {
    if (area.x1 < 0 or area.y1 < 0) return;

    const w_i32 = area.x2 - area.x1 + 1;
    const h_i32 = area.y2 - area.y1 + 1;
    if (w_i32 <= 0 or h_i32 <= 0) return;

    const x: u16 = @intCast(area.x1);
    const y: u16 = @intCast(area.y1);
    const w: u16 = @intCast(w_i32);
    const h: u16 = @intCast(h_i32);
    const count = @as(usize, w) * @as(usize, h);
    if (count > self.flush_buffer.len) return;

    switch (self.color_format) {
        binding.LV_COLOR_FORMAT_RGB888 => self.copyRgb888(px_map, count),
        else => return,
    }

    self.display.drawBitmap(x, y, w, h, self.flush_buffer[0..count]) catch {};
}

fn copyRgb888(self: *LvglDisplay, px_map: *const u8, count: usize) void {
    const bytes: [*]const u8 = @ptrCast(px_map);
    for (0..count) |index| {
        const base = index * 3;
        self.flush_buffer[index] = switch (self.rgb888_byte_order) {
            .rgb => DisplayApi.rgb(
                bytes[base],
                bytes[base + 1],
                bytes[base + 2],
            ),
            .bgr => DisplayApi.rgb(
                bytes[base + 2],
                bytes[base + 1],
                bytes[base],
            ),
        };
    }
}

fn flushCb(
    display: ?*binding.Display,
    area: ?*const binding.Area,
    px_map: ?*u8,
) callconv(.c) void {
    defer if (display) |display_handle| binding.lv_display_flush_ready(display_handle);

    const display_handle = display orelse return;
    const user_data = binding.lv_display_get_user_data(display_handle) orelse return;
    const self: *LvglDisplay = @ptrCast(@alignCast(user_data));
    const draw_area = area orelse return;
    const pixels = px_map orelse return;
    self.flush(draw_area, @ptrCast(pixels));
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn createsLvglDisplayAndFlushesToEmbedDisplay(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            const Backend = struct {
                draws: usize = 0,
                last_x: u16 = 0,
                last_y: u16 = 0,
                last_w: u16 = 0,
                last_h: u16 = 0,
                pixels: [2]DisplayApi.Rgb = undefined,

                fn deinitFn(_: *anyopaque) void {}

                fn widthFn(_: *anyopaque) u16 {
                    return 4;
                }

                fn heightFn(_: *anyopaque) u16 {
                    return 3;
                }

                fn maxFlushPixelsFn(_: *anyopaque) DisplayApi.Error!usize {
                    return 4 * 3;
                }

                fn flushFn(
                    ptr: *anyopaque,
                    x: u16,
                    y: u16,
                    w: u16,
                    h: u16,
                    pixels: []const DisplayApi.Rgb,
                ) DisplayApi.Error!void {
                    const backend: *@This() = @ptrCast(@alignCast(ptr));
                    backend.draws += 1;
                    backend.last_x = x;
                    backend.last_y = y;
                    backend.last_w = w;
                    backend.last_h = h;
                    backend.pixels[0] = pixels[0];
                    backend.pixels[1] = pixels[1];
                }

                const vtable = DisplayApi.VTable{
                    .deinit = deinitFn,
                    .width = widthFn,
                    .height = heightFn,
                    .maxFlushPixels = maxFlushPixelsFn,
                    .flush = flushFn,
                };

                fn api(self: *@This()) DisplayApi {
                    return .{
                        .ptr = self,
                        .vtable = &vtable,
                    };
                }
            };

            binding.lv_init();
            defer binding.lv_deinit();

            var backend = Backend{};
            var draw_buffer: [4 * 3 * 3]u8 align(8) = undefined;
            var flush_buffer: [2]DisplayApi.Rgb = undefined;
            var adapter = LvglDisplay{};
            defer adapter.deinit();

            try adapter.init(.{
                .display = backend.api(),
                .draw_buffer = draw_buffer[0..],
                .flush_buffer = flush_buffer[0..],
                .rgb888_byte_order = .bgr,
            });

            var area = binding.Area{
                .x1 = 1,
                .y1 = 1,
                .x2 = 2,
                .y2 = 1,
            };
            var pixel_bytes = [_]u8{
                3, 2, 1,
                6, 5, 4,
            };

            flushCb(adapter.raw(), &area, @ptrCast(pixel_bytes[0..].ptr));

            try grt.std.testing.expectEqual(@as(usize, 1), backend.draws);
            try grt.std.testing.expectEqual(@as(u16, 1), backend.last_x);
            try grt.std.testing.expectEqual(@as(u16, 1), backend.last_y);
            try grt.std.testing.expectEqual(@as(u16, 2), backend.last_w);
            try grt.std.testing.expectEqual(@as(u16, 1), backend.last_h);
            try grt.std.testing.expectEqual(DisplayApi.rgb(1, 2, 3), backend.pixels[0]);
            try grt.std.testing.expectEqual(DisplayApi.rgb(4, 5, 6), backend.pixels[1]);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run(
                "lvgl/unit_tests/embed.LvglDisplay/creates_lvgl_display_and_flushes_to_embed_display",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.createsLvglDisplayAndFlushesToEmbedDisplay),
            );
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
