const dep = @import("dep");
const embed = dep.embed;
const embed_std = dep.embed_std;
const ledstrip = dep.ledstrip;

pub const Snapshot = struct {
    pixels: []const ledstrip.Color,
    refresh_count: usize,
};

pub const LedStrip = struct {
    pub const RefreshHook = *const fn (ctx: *anyopaque, strip: *LedStrip) void;

    allocator: embed.mem.Allocator,
    mutex: embed_std.std.Thread.Mutex = .{},
    pixels: []ledstrip.Color,
    refresh_count: usize = 0,
    refresh_ctx: ?*anyopaque = null,
    refresh_hook: ?RefreshHook = null,

    pub fn init(allocator: embed.mem.Allocator, pixel_count: usize) !@This() {
        const pixels = try allocator.alloc(ledstrip.Color, pixel_count);
        errdefer allocator.free(pixels);

        for (pixels) |*entry| {
            entry.* = ledstrip.Color.black;
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

    pub fn handle(self: *@This()) ledstrip.LedStrip {
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

    pub fn setPixel(self: *@This(), index: usize, color: ledstrip.Color) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.pixels.len) return;
        self.pixels[index] = color;
    }

    pub fn pixel(self: *@This(), index: usize) ledstrip.Color {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.pixels.len) return ledstrip.Color.black;
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

    const vtable = ledstrip.LedStrip.VTable{
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
            fn call(ptr: *anyopaque, index: usize, color: ledstrip.Color) void {
                const self: *LedStrip = @ptrCast(@alignCast(ptr));
                self.setPixel(index, color);
            }
        }.call,
        .pixel = struct {
            fn call(ptr: *anyopaque, index: usize) ledstrip.Color {
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

pub fn TestRunner(comptime lib: type) dep.testing.TestRunner {
    const testing_api = dep.testing;

    const TestCase = struct {
        fn ledstripTracksPixels() !void {
            var strip = try LedStrip.init(lib.testing.allocator, 3);
            defer strip.deinit();

            const handle = strip.handle();
            handle.setPixel(0, ledstrip.Color.red);
            handle.setPixel(1, ledstrip.Color.green);
            handle.refresh();

            const snapshot = strip.snapshot();
            try lib.testing.expectEqual(@as(usize, 3), snapshot.pixels.len);
            try lib.testing.expectEqual(ledstrip.Color.red, snapshot.pixels[0]);
            try lib.testing.expectEqual(ledstrip.Color.green, snapshot.pixels[1]);
            try lib.testing.expectEqual(@as(usize, 1), snapshot.refresh_count);
        }

        fn ledstripRefreshHook() !void {
            const Sink = struct {
                called: usize = 0,
                last_color: ledstrip.Color = ledstrip.Color.black,

                fn onRefresh(ctx: *anyopaque, strip: *LedStrip) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    const snapshot = strip.snapshot();
                    self.called += 1;
                    if (snapshot.pixels.len > 0) {
                        self.last_color = snapshot.pixels[0];
                    }
                }
            };

            var strip = try LedStrip.init(lib.testing.allocator, 1);
            defer strip.deinit();

            var sink = Sink{};
            strip.setRefreshHook(&sink, Sink.onRefresh);
            strip.handle().setPixel(0, ledstrip.Color.blue);
            strip.handle().refresh();

            try lib.testing.expectEqual(@as(usize, 1), sink.called);
            try lib.testing.expectEqual(ledstrip.Color.blue, sink.last_color);

            strip.clearRefreshHook();
            strip.handle().setPixel(0, ledstrip.Color.red);
            strip.handle().refresh();
            try lib.testing.expectEqual(@as(usize, 1), sink.called);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
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

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
