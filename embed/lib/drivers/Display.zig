//! drivers.Display - type-erased display adapter bundle.

const glib = @import("glib");

const root = @This();

pub const Error = error{
    OutOfBounds,
    Busy,
    Timeout,
    DisplayError,
};

pub const Rgb = @import("display/Rgb.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    width: *const fn (ptr: *anyopaque) u16,
    height: *const fn (ptr: *anyopaque) u16,
    drawBitmap: *const fn (
        ptr: *anyopaque,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        pixels: []const Rgb,
    ) Error!void,
};

pub fn rgb(r: u8, g: u8, b: u8) Rgb {
    return Rgb.init(r, g, b);
}

pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn width(self: root) u16 {
    return self.vtable.width(self.ptr);
}

pub fn height(self: root) u16 {
    return self.vtable.height(self.ptr);
}

/// `pixels` is a contiguous row-major RGB buffer with at least `w * h` entries.
pub fn drawBitmap(
    self: root,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const Rgb,
) Error!void {
    if (w == 0 or h == 0) return;
    if (@as(u32, x) + w > self.width() or @as(u32, y) + h > self.height()) {
        return error.OutOfBounds;
    }
    if (pixels.len < @as(usize, w) * @as(usize, h)) {
        return error.OutOfBounds;
    }
    return self.vtable.drawBitmap(self.ptr, x, y, w, h, pixels);
}

pub fn make(comptime grt: type, comptime Impl: type) type {
    _ = grt;
    comptime {
        if (!@hasDecl(Impl, "Config")) @compileError("Display impl must define Config");
        if (!@hasDecl(Impl, "init")) @compileError("Display impl must define init");
        if (!@hasDecl(Impl, "deinit")) @compileError("Display impl must define deinit");
        if (!@hasDecl(Impl, "width")) @compileError("Display impl must define width");
        if (!@hasDecl(Impl, "height")) @compileError("Display impl must define height");
        if (!@hasDecl(Impl, "drawBitmap")) @compileError("Display impl must define drawBitmap");
        if (!@hasField(Impl.Config, "allocator")) @compileError("Display impl Config must define allocator");

        _ = @as(*const fn (Impl.Config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) u16, &Impl.width);
        _ = @as(*const fn (*Impl) u16, &Impl.height);
        _ = @as(
            *const fn (*Impl, u16, u16, u16, u16, []const Rgb) anyerror!void,
            &Impl.drawBitmap,
        );
    }

    const Allocator = glib.std.mem.Allocator;
    const Ctx = struct {
        allocator: Allocator,
        impl: Impl,

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
            self.allocator.destroy(self);
        }

        pub fn width(self: *@This()) u16 {
            return self.impl.width();
        }

        pub fn height(self: *@This()) u16 {
            return self.impl.height();
        }

        pub fn drawBitmap(
            self: *@This(),
            x: u16,
            y: u16,
            w: u16,
            h: u16,
            pixels: []const Rgb,
        ) Error!void {
            return self.impl.drawBitmap(x, y, w, h, pixels) catch |err| switch (err) {
                error.OutOfBounds => error.OutOfBounds,
                error.Busy => error.Busy,
                error.Timeout => error.Timeout,
                else => error.DisplayError,
            };
        }
    };
    const VTableGen = struct {
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn widthFn(ptr: *anyopaque) u16 {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.width();
        }

        fn heightFn(ptr: *anyopaque) u16 {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.height();
        }

        fn drawBitmapFn(
            ptr: *anyopaque,
            x: u16,
            y: u16,
            w: u16,
            h: u16,
            pixels: []const Rgb,
        ) Error!void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.drawBitmap(x, y, w, h, pixels);
        }

        const vtable = VTable{
            .deinit = deinitFn,
            .width = widthFn,
            .height = heightFn,
            .drawBitmap = drawBitmapFn,
        };
    };

    return struct {
        pub const Config = Impl.Config;

        pub fn init(config: Config) !root {
            var impl = try Impl.init(config);
            errdefer impl.deinit();

            const storage = try config.allocator.create(Ctx);
            errdefer config.allocator.destroy(storage);
            storage.* = .{
                .allocator = config.allocator,
                .impl = impl,
            };
            return .{
                .ptr = storage,
                .vtable = &VTableGen.vtable,
            };
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn exposesGeometryAndDrawVtableSurface(allocator: glib.std.mem.Allocator) !void {
            const State = struct {
                deinit_calls: usize = 0,
                draws: usize = 0,
                last_x: u16 = 0,
                last_y: u16 = 0,
                last_w: u16 = 0,
                last_h: u16 = 0,
                last_pixels: []const Rgb = &.{},
            };

            const Impl = struct {
                pub const Config = struct {
                    allocator: glib.std.mem.Allocator,
                    state: *State,
                    width_px: u16 = 8,
                    height_px: u16 = 4,
                };

                state: *State,
                width_px: u16,
                height_px: u16,

                pub fn init(config: Config) !@This() {
                    return .{
                        .state = config.state,
                        .width_px = config.width_px,
                        .height_px = config.height_px,
                    };
                }

                pub fn deinit(self: *@This()) void {
                    self.state.deinit_calls += 1;
                }

                pub fn width(self: *@This()) u16 {
                    return self.width_px;
                }

                pub fn height(self: *@This()) u16 {
                    return self.height_px;
                }

                pub fn drawBitmap(
                    self: *@This(),
                    x: u16,
                    y: u16,
                    w: u16,
                    h: u16,
                    pixels: []const Rgb,
                ) Error!void {
                    self.state.draws += 1;
                    self.state.last_x = x;
                    self.state.last_y = y;
                    self.state.last_w = w;
                    self.state.last_h = h;
                    self.state.last_pixels = pixels;
                }
            };

            var state = State{};
            var display = try make(grt, Impl).init(.{
                .allocator = allocator,
                .state = &state,
            });
            defer display.deinit();

            const pixels = [_]Rgb{
                rgb(255, 0, 0),
                rgb(0, 255, 0),
                rgb(0, 0, 255),
                rgb(255, 255, 255),
            };

            try grt.std.testing.expectEqual(@as(u16, 8), display.width());
            try grt.std.testing.expectEqual(@as(u16, 4), display.height());
            try display.drawBitmap(1, 1, 2, 2, &pixels);
            try grt.std.testing.expectEqual(@as(usize, 1), state.draws);
            try grt.std.testing.expectEqual(@as(u16, 1), state.last_x);
            try grt.std.testing.expectEqual(@as(u16, 1), state.last_y);
            try grt.std.testing.expectEqual(@as(u16, 2), state.last_w);
            try grt.std.testing.expectEqual(@as(u16, 2), state.last_h);
            try grt.std.testing.expectEqualSlices(Rgb, pixels[0..], state.last_pixels);

            comptime {
                _ = root.deinit;
                _ = root.width;
                _ = root.height;
                _ = root.drawBitmap;
                _ = root.rgb;
                _ = root.make;
                _ = make(grt, Impl).init;
                if (!@hasField(make(grt, Impl).Config, "allocator")) {
                    @compileError("make config must expose allocator");
                }
            }
        }

        fn validatesBoundsBeforeCallingBackend(allocator: glib.std.mem.Allocator) !void {
            const State = struct {
                draws: usize = 0,
            };

            const Impl = struct {
                pub const Config = struct {
                    allocator: glib.std.mem.Allocator,
                    state: *State,
                };

                state: *State,

                pub fn init(config: Config) !@This() {
                    return .{
                        .state = config.state,
                    };
                }

                pub fn deinit(_: *@This()) void {}

                pub fn width(_: *@This()) u16 {
                    return 4;
                }

                pub fn height(_: *@This()) u16 {
                    return 4;
                }

                pub fn drawBitmap(
                    self: *@This(),
                    _: u16,
                    _: u16,
                    _: u16,
                    _: u16,
                    _: []const Rgb,
                ) Error!void {
                    self.state.draws += 1;
                }
            };

            var state = State{};
            var display = try make(grt, Impl).init(.{
                .allocator = allocator,
                .state = &state,
            });
            defer display.deinit();

            const pixels = [_]Rgb{rgb(255, 0, 0)} ** 4;

            try grt.std.testing.expectError(error.OutOfBounds, display.drawBitmap(3, 3, 2, 2, &pixels));
            try grt.std.testing.expectError(error.OutOfBounds, display.drawBitmap(0, 0, 2, 2, pixels[0..3]));
            try grt.std.testing.expectEqual(@as(usize, 0), state.draws);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.exposesGeometryAndDrawVtableSurface(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.validatesBoundsBeforeCallingBackend(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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
