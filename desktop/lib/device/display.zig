const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

const DisplayApi = embed.drivers.Display;

pub const Display = struct {
    pub const width_px: u16 = 320;
    pub const height_px: u16 = 240;
    const pixel_count = @as(usize, width_px) * @as(usize, height_px);

    allocator: glib.std.mem.Allocator,
    mutex: gstd.runtime.std.Thread.Mutex = .{},
    pixels: []DisplayApi.Rgb,
    enabled: bool = false,
    brightness: u8 = 0,
    refresh_count: usize = 0,
    refresh_ctx: ?*anyopaque = null,
    refresh_hook: ?*const fn (ctx: *anyopaque, display: *Display, update: Update) void = null,

    pub const Update = struct {
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        pixels: []const DisplayApi.Rgb,
        refresh_count: usize,
    };

    pub const Snapshot = struct {
        width: u16,
        height: u16,
        pixels: []DisplayApi.Rgb,
        refresh_count: usize,
    };

    pub fn init(allocator: glib.std.mem.Allocator) !Display {
        const pixels = try allocator.alloc(DisplayApi.Rgb, pixel_count);
        for (pixels) |*pixel| pixel.* = DisplayApi.rgb(0, 0, 0);
        return .{
            .allocator = allocator,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Display) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn handle(self: *Display) DisplayApi {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn snapshot(self: *Display, allocator: glib.std.mem.Allocator) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pixels = try allocator.dupe(DisplayApi.Rgb, self.pixels);
        return .{
            .width = width_px,
            .height = height_px,
            .pixels = pixels,
            .refresh_count = self.refresh_count,
        };
    }

    pub fn setRefreshHook(self: *Display, ctx: *anyopaque, hook: *const fn (ctx: *anyopaque, display: *Display, update: Update) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refresh_ctx = ctx;
        self.refresh_hook = hook;
    }

    fn deinitFn(_: *anyopaque) void {}

    fn widthFn(_: *anyopaque) u16 {
        return width_px;
    }

    fn heightFn(_: *anyopaque) u16 {
        return height_px;
    }

    fn setEnabledFn(ptr: *anyopaque, enabled: bool) DisplayApi.Error!void {
        const self: *Display = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enabled = enabled;
    }

    fn enabledFn(ptr: *anyopaque) DisplayApi.Error!bool {
        const self: *Display = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.enabled;
    }

    fn setBrightnessFn(ptr: *anyopaque, brightness: u8) DisplayApi.Error!void {
        const self: *Display = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.brightness = brightness;
    }

    fn brightnessFn(ptr: *anyopaque) DisplayApi.Error!u8 {
        const self: *Display = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.brightness;
    }

    fn drawBitmapFn(
        ptr: *anyopaque,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        pixels: []const DisplayApi.Rgb,
    ) DisplayApi.Error!void {
        const self: *Display = @ptrCast(@alignCast(ptr));
        if (@as(u32, x) + w > width_px or @as(u32, y) + h > height_px) return error.OutOfBounds;
        if (pixels.len < @as(usize, w) * @as(usize, h)) return error.OutOfBounds;

        const count = @as(usize, w) * @as(usize, h);
        const refresh = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (0..h) |row| {
                const dst_start = (@as(usize, y) + row) * width_px + x;
                const src_start = row * w;
                @memcpy(
                    self.pixels[dst_start .. dst_start + w],
                    pixels[src_start .. src_start + w],
                );
            }
            self.refresh_count += 1;
            break :blk .{
                .ctx = self.refresh_ctx,
                .hook = self.refresh_hook,
                .update = Update{
                    .x = x,
                    .y = y,
                    .w = w,
                    .h = h,
                    .pixels = pixels[0..count],
                    .refresh_count = self.refresh_count,
                },
            };
        };

        if (refresh.ctx) |ctx| {
            if (refresh.hook) |hook| {
                hook(ctx, self, refresh.update);
            }
        }
    }

    const vtable = DisplayApi.VTable{
        .deinit = deinitFn,
        .width = widthFn,
        .height = heightFn,
        .setEnabled = setEnabledFn,
        .enabled = enabledFn,
        .setBrightness = setBrightnessFn,
        .brightness = brightnessFn,
        .drawBitmap = drawBitmapFn,
    };
};

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: std.mem.Allocator) bool {
            _ = self;
            var display = Display.init(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer display.deinit();

            var api = display.handle();
            const pixels = [_]DisplayApi.Rgb{
                DisplayApi.rgb(1, 2, 3),
                DisplayApi.rgb(4, 5, 6),
            };
            api.drawBitmap(1, 1, 2, 1, pixels[0..]) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            const snapshot = display.snapshot(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer allocator.free(snapshot.pixels);

            std.testing.expectEqual(@as(usize, 1), snapshot.refresh_count) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expectEqual(DisplayApi.rgb(1, 2, 3), snapshot.pixels[@as(usize, Display.width_px) + 1]) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
