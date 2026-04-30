const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

pub const Snapshot = struct {
    pixels: []const embed.ledstrip.Color,
    refresh_count: usize,
};

pub const LedStrip = struct {
    pub const RefreshHook = *const fn (ctx: *anyopaque, strip: *LedStrip) void;

    allocator: gstd.runtime.std.mem.Allocator,
    mutex: gstd.runtime.std.Thread.Mutex = .{},
    pixels: []embed.ledstrip.Color,
    refresh_count: usize = 0,
    refresh_ctx: ?*anyopaque = null,
    refresh_hook: ?RefreshHook = null,

    pub fn init(allocator: gstd.runtime.std.mem.Allocator, pixel_count: usize) !@This() {
        const pixels = try allocator.alloc(embed.ledstrip.Color, pixel_count);
        errdefer allocator.free(pixels);

        for (pixels) |*entry| {
            entry.* = embed.ledstrip.Color.black;
        }

        return .{
            .allocator = allocator,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn handle(self: *@This()) embed.ledstrip.LedStrip {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn snapshot(self: *@This()) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .pixels = self.pixels,
            .refresh_count = self.refresh_count,
        };
    }

    pub fn setRefreshHook(self: *@This(), ctx: *anyopaque, hook: RefreshHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refresh_ctx = ctx;
        self.refresh_hook = hook;
    }

    pub fn clearRefreshHook(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refresh_ctx = null;
        self.refresh_hook = null;
    }

    pub fn count(self: *@This()) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pixels.len;
    }

    pub fn setPixel(self: *@This(), index: usize, color: embed.ledstrip.Color) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.pixels.len) return;
        self.pixels[index] = color;
    }

    pub fn pixel(self: *@This(), index: usize) embed.ledstrip.Color {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.pixels.len) return embed.ledstrip.Color.black;
        return self.pixels[index];
    }

    pub fn refresh(self: *@This()) void {
        self.mutex.lock();
        self.refresh_count += 1;
        const hook = self.refresh_hook;
        const ctx = self.refresh_ctx;
        self.mutex.unlock();

        if (hook) |callback| {
            const callback_ctx = ctx orelse return;
            callback(callback_ctx, self);
        }
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
};

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const TestCase = struct {
        fn ledstripTracksPixels() !void {
            var strip = try LedStrip.init(std.testing.allocator, 3);
            defer strip.deinit();

            const handle = strip.handle();
            handle.setPixel(0, embed.ledstrip.Color.red);
            handle.setPixel(1, embed.ledstrip.Color.green);
            handle.refresh();

            const snapshot = strip.snapshot();
            try std.testing.expectEqual(@as(usize, 3), snapshot.pixels.len);
            try std.testing.expectEqual(embed.ledstrip.Color.red, snapshot.pixels[0]);
            try std.testing.expectEqual(embed.ledstrip.Color.green, snapshot.pixels[1]);
            try std.testing.expectEqual(@as(usize, 1), snapshot.refresh_count);
        }

        fn ledstripRefreshHook() !void {
            const Sink = struct {
                called: usize = 0,
                last_color: embed.ledstrip.Color = embed.ledstrip.Color.black,

                fn onRefresh(ctx: *anyopaque, strip: *LedStrip) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    const snapshot = strip.snapshot();
                    self.called += 1;
                    if (snapshot.pixels.len > 0) {
                        self.last_color = snapshot.pixels[0];
                    }
                }
            };

            var strip = try LedStrip.init(std.testing.allocator, 1);
            defer strip.deinit();

            var sink = Sink{};
            strip.setRefreshHook(&sink, Sink.onRefresh);
            strip.handle().setPixel(0, embed.ledstrip.Color.blue);
            strip.handle().refresh();

            try std.testing.expectEqual(@as(usize, 1), sink.called);
            try std.testing.expectEqual(embed.ledstrip.Color.blue, sink.last_color);

            strip.clearRefreshHook();
            strip.handle().setPixel(0, embed.ledstrip.Color.red);
            strip.handle().refresh();
            try std.testing.expectEqual(@as(usize, 1), sink.called);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.ledstripTracksPixels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.ledstripRefreshHook() catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
