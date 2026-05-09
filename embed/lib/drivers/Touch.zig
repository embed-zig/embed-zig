//! Touch — non-owning type-erased touch-panel reader.

const glib = @import("glib");

const Touch = @This();

pub const Ft5x06 = @import("touch/ft5x06.zig");

pub const max_points: usize = 5;

pub const Point = struct {
    id: u8 = 0,
    x: u16,
    y: u16,
    pressure: ?u16 = null,
};

pub const Event = struct {
    pressed: bool,
    point_count: usize = 0,
    primary: ?Point = null,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, event: Event) void;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque, points: []Point) anyerror!usize,
    setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void,
    clearEventCallback: *const fn (ptr: *anyopaque) void,
};

pub fn read(self: Touch, points: []Point) ![]const Point {
    const count = try self.vtable.read(self.ptr, points);
    if (count > points.len) return error.TooManyPoints;
    return points[0..count];
}

pub fn setEventCallback(self: Touch, ctx: *const anyopaque, emit_fn: CallbackFn) void {
    self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
}

pub fn clearEventCallback(self: Touch) void {
    self.vtable.clearEventCallback(self.ptr);
}

pub fn init(pointer: anytype) Touch {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("Touch.init expects a single-item pointer");
    }

    const Impl = info.pointer.child;

    const gen = struct {
        fn readFn(ptr: *anyopaque, points: []Point) anyerror!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(points);
        }

        fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }

        fn clearEventCallbackFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }

        const vtable = VTable{
            .read = readFn,
            .setEventCallback = setEventCallbackFn,
            .clearEventCallback = clearEventCallbackFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn forwardsReadIntoCallerBuffer() !void {
            const Impl = struct {
                read_count: usize = 0,
                receiver_ctx: ?*const anyopaque = null,
                emit_fn: ?CallbackFn = null,

                pub fn read(self: *@This(), points: []Point) !usize {
                    self.read_count += 1;
                    points[0] = .{ .id = 3, .x = 12, .y = 34, .pressure = 56 };
                    return 1;
                }

                pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    self.receiver_ctx = ctx;
                    self.emit_fn = emit_fn;
                }

                pub fn clearEventCallback(self: *@This()) void {
                    self.receiver_ctx = null;
                    self.emit_fn = null;
                }
            };

            var impl = Impl{};
            const touch = Touch.init(&impl);
            var points: [max_points]Point = undefined;
            const sample = try touch.read(points[0..]);

            try grt.std.testing.expectEqual(@as(usize, 1), impl.read_count);
            try grt.std.testing.expectEqual(@as(usize, 1), sample.len);
            try grt.std.testing.expectEqual(@as(u8, 3), sample[0].id);
            try grt.std.testing.expectEqual(@as(u16, 12), sample[0].x);
            try grt.std.testing.expectEqual(@as(u16, 34), sample[0].y);
            try grt.std.testing.expectEqual(@as(?u16, 56), sample[0].pressure);
        }

        fn rejectsBackendCountLargerThanBuffer() !void {
            const Impl = struct {
                pub fn read(_: *@This(), _: []Point) !usize {
                    return max_points + 1;
                }

                pub fn setEventCallback(_: *@This(), _: *const anyopaque, _: CallbackFn) void {}

                pub fn clearEventCallback(_: *@This()) void {}
            };

            var impl = Impl{};
            const touch = Touch.init(&impl);
            var points: [max_points]Point = undefined;
            try grt.std.testing.expectError(error.TooManyPoints, touch.read(points[0..]));
        }

        fn initSetsAndClearsEventCallback() !void {
            const Impl = struct {
                receiver_ctx: ?*const anyopaque = null,
                emit_fn: ?CallbackFn = null,

                pub fn read(_: *@This(), _: []Point) !usize {
                    return 0;
                }

                pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    self.receiver_ctx = ctx;
                    self.emit_fn = emit_fn;
                }

                pub fn clearEventCallback(self: *@This()) void {
                    self.receiver_ctx = null;
                    self.emit_fn = null;
                }
            };

            var impl = Impl{};
            const touch = Touch.init(&impl);
            const callback_ctx: usize = 0x1234;
            const callback = struct {
                fn emitFn(_: *const anyopaque, _: Event) void {}
            }.emitFn;

            touch.setEventCallback(@ptrFromInt(callback_ctx), callback);
            try grt.std.testing.expectEqual(@as(?*const anyopaque, @ptrFromInt(callback_ctx)), impl.receiver_ctx);
            try grt.std.testing.expect(impl.emit_fn != null);

            touch.clearEventCallback();
            try grt.std.testing.expect(impl.receiver_ctx == null);
            try grt.std.testing.expect(impl.emit_fn == null);
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

            TestCase.forwardsReadIntoCallerBuffer() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsBackendCountLargerThanBuffer() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.initSetsAndClearsEventCallback() catch |err| {
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
