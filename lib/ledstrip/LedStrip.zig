//! ledstrip.LedStrip — type-erased LED strip adapter bundle.

const embed = @import("embed");
const Color = @import("Color.zig");

const root = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    count: *const fn (ptr: *anyopaque) usize,
    setPixel: *const fn (ptr: *anyopaque, index: usize, color: Color) void,
    pixel: *const fn (ptr: *anyopaque, index: usize) Color,
    refresh: *const fn (ptr: *anyopaque) void,
};

pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn count(self: root) usize {
    return self.vtable.count(self.ptr);
}

pub fn setPixel(self: root, index: usize, color: Color) void {
    self.vtable.setPixel(self.ptr, index, color);
}

pub fn pixel(self: root, index: usize) Color {
    return self.vtable.pixel(self.ptr, index);
}

pub fn setPixels(self: root, start: usize, pixels: []const Color) void {
    const pixel_count = self.count();
    if (start >= pixel_count or pixels.len == 0) return;

    const limit = @min(pixels.len, pixel_count - start);
    for (pixels[0..limit], 0..) |color, offset| {
        self.setPixel(start + offset, color);
    }
}

pub fn fill(self: root, color: Color) void {
    for (0..self.count()) |index| {
        self.setPixel(index, color);
    }
}

pub fn clear(self: root) void {
    self.fill(Color.black);
}

pub fn refresh(self: root) void {
    self.vtable.refresh(self.ptr);
}

pub fn make(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "Config")) @compileError("LedStrip impl must define Config");
        if (!@hasDecl(Impl, "init")) @compileError("LedStrip impl must define init");
        if (!@hasDecl(Impl, "deinit")) @compileError("LedStrip impl must define deinit");
        if (!@hasDecl(Impl, "count")) @compileError("LedStrip impl must define count");
        if (!@hasDecl(Impl, "setPixel")) @compileError("LedStrip impl must define setPixel");
        if (!@hasDecl(Impl, "pixel")) @compileError("LedStrip impl must define pixel");
        if (!@hasDecl(Impl, "refresh")) @compileError("LedStrip impl must define refresh");
        if (!@hasField(Impl.Config, "allocator")) @compileError("LedStrip impl Config must define allocator");

        _ = @as(*const fn (Impl.Config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) usize, &Impl.count);
        _ = @as(*const fn (*Impl, usize, Color) void, &Impl.setPixel);
        _ = @as(*const fn (*Impl, usize) Color, &Impl.pixel);
        _ = @as(*const fn (*Impl) void, &Impl.refresh);
    }

    const Ctx = struct {
        allocator: embed.mem.Allocator,
        impl: Impl,

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
            self.allocator.destroy(self);
        }

        pub fn count(self: *@This()) usize {
            return self.impl.count();
        }

        pub fn setPixel(self: *@This(), index: usize, color: Color) void {
            self.impl.setPixel(index, color);
        }

        pub fn pixel(self: *@This(), index: usize) Color {
            return self.impl.pixel(index);
        }

        pub fn refresh(self: *@This()) void {
            self.impl.refresh();
        }
    };
    const VTableGen = struct {
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn countFn(ptr: *anyopaque) usize {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.count();
        }

        fn setPixelFn(ptr: *anyopaque, index: usize, color: Color) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.setPixel(index, color);
        }

        fn pixelFn(ptr: *anyopaque, index: usize) Color {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.pixel(index);
        }

        fn refreshFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.refresh();
        }

        const vtable = VTable{
            .deinit = deinitFn,
            .count = countFn,
            .setPixel = setPixelFn,
            .pixel = pixelFn,
            .refresh = refreshFn,
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

test "ledstrip/unit_tests/LedStrip_exposes_vtable_surface" {
    const std = @import("std");
    const testing = std.testing;

    const State = struct {
        deinit_calls: usize = 0,
        refresh_calls: usize = 0,
        pixels: [8]Color = [_]Color{Color.black} ** 8,
    };

    const Impl = struct {
        pub const Config = struct {
            allocator: std.mem.Allocator,
            state: *State,
            pixel_count: usize = 8,
        };

        state: *State,
        pixel_count: usize,

        pub fn init(config: Config) !@This() {
            return .{
                .state = config.state,
                .pixel_count = config.pixel_count,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.state.deinit_calls += 1;
        }

        pub fn count(self: *@This()) usize {
            return self.pixel_count;
        }

        pub fn setPixel(self: *@This(), index: usize, color: Color) void {
            if (index >= self.pixel_count) return;
            self.state.pixels[index] = color;
        }

        pub fn pixel(self: *@This(), index: usize) Color {
            if (index >= self.pixel_count) return Color.black;
            return self.state.pixels[index];
        }

        pub fn refresh(self: *@This()) void {
            self.state.refresh_calls += 1;
        }
    };

    var state = State{};
    var strip = try make(Impl).init(.{
        .allocator = testing.allocator,
        .state = &state,
        .pixel_count = 5,
    });
    defer strip.deinit();

    strip.setPixel(0, Color.red);
    strip.setPixels(1, &[_]Color{ Color.green, Color.blue, Color.white });
    strip.refresh();

    try testing.expectEqual(@as(usize, 5), strip.count());
    try testing.expectEqual(Color.red, strip.pixel(0));
    try testing.expectEqual(Color.green, strip.pixel(1));
    try testing.expectEqual(Color.blue, strip.pixel(2));
    try testing.expectEqual(Color.white, strip.pixel(3));
    try testing.expectEqual(@as(usize, 1), state.refresh_calls);

    comptime {
        _ = root.deinit;
        _ = root.count;
        _ = root.setPixel;
        _ = root.pixel;
        _ = root.setPixels;
        _ = root.fill;
        _ = root.clear;
        _ = root.refresh;
        _ = root.make;
        _ = make(Impl).init;
        if (!@hasField(make(Impl).Config, "allocator")) {
            @compileError("make config must expose allocator");
        }
    }
}

test "ledstrip/unit_tests/LedStrip_helper_methods_respect_strip_bounds" {
    const std = @import("std");
    const testing = std.testing;

    const State = struct {
        pixels: [4]Color = [_]Color{Color.black} ** 4,
    };

    const Impl = struct {
        pub const Config = struct {
            allocator: std.mem.Allocator,
            state: *State,
        };

        state: *State,

        pub fn init(config: Config) !@This() {
            return .{ .state = config.state };
        }

        pub fn deinit(_: *@This()) void {}

        pub fn count(_: *@This()) usize {
            return 4;
        }

        pub fn setPixel(self: *@This(), index: usize, color: Color) void {
            if (index >= self.state.pixels.len) return;
            self.state.pixels[index] = color;
        }

        pub fn pixel(self: *@This(), index: usize) Color {
            if (index >= self.state.pixels.len) return Color.black;
            return self.state.pixels[index];
        }

        pub fn refresh(_: *@This()) void {}
    };

    var state = State{};
    var strip = try make(Impl).init(.{
        .allocator = testing.allocator,
        .state = &state,
    });
    defer strip.deinit();

    strip.setPixels(2, &[_]Color{ Color.red, Color.green, Color.blue });
    try testing.expectEqual(Color.red, strip.pixel(2));
    try testing.expectEqual(Color.green, strip.pixel(3));

    strip.fill(Color.white);
    for (0..strip.count()) |index| {
        try testing.expectEqual(Color.white, strip.pixel(index));
    }

    strip.clear();
    for (0..strip.count()) |index| {
        try testing.expectEqual(Color.black, strip.pixel(index));
    }
}
