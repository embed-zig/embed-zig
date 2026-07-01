const glib = @import("glib");
const gstd = @import("gstd");
const drivers = @import("embed").drivers;

const Pin = @This();

mutex: gstd.runtime.sync.Mutex = .{},
level: drivers.Gpio.Level = .low,
direction: drivers.Gpio.Direction = .input,
interrupt_edge: ?drivers.Gpio.Edge = null,
callback_ctx: ?*const anyopaque = null,
callback_fn: ?drivers.Gpio.CallbackFn = null,

pub fn init(level: drivers.Gpio.Level) Pin {
    return .{
        .level = level,
    };
}

pub fn handle(self: *Pin) drivers.Gpio {
    return drivers.Gpio.init(self);
}

pub fn read(self: *Pin) drivers.Gpio.Error!drivers.Gpio.Level {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.level;
}

pub fn write(self: *Pin, level: drivers.Gpio.Level) drivers.Gpio.Error!void {
    const event = blk: {
        self.mutex.lock();
        defer self.mutex.unlock();

        const previous = self.level;
        self.level = level;
        const edge = edgeFromTransition(previous, level);
        if (!shouldEmit(self.interrupt_edge, previous, level, edge)) break :blk null;
        break :blk drivers.Gpio.Event{
            .edge = edge,
            .level = level,
        };
    };

    if (event) |value| self.emit(value);
}

pub fn setDirection(self: *Pin, direction: drivers.Gpio.Direction) drivers.Gpio.Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.direction = direction;
}

pub fn configureInterrupt(self: *Pin, edge: drivers.Gpio.Edge) drivers.Gpio.Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.interrupt_edge = edge;
}

pub fn setEventCallback(self: *Pin, ctx: *const anyopaque, emit_fn: drivers.Gpio.CallbackFn) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.callback_ctx = ctx;
    self.callback_fn = emit_fn;
}

pub fn clearEventCallback(self: *Pin) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.callback_ctx = null;
    self.callback_fn = null;
}

pub fn setLevel(self: *Pin, level: drivers.Gpio.Level) drivers.Gpio.Error!void {
    try self.write(level);
}

pub fn toggle(self: *Pin) drivers.Gpio.Error!void {
    const next = switch (try self.read()) {
        .low => drivers.Gpio.Level.high,
        .high => drivers.Gpio.Level.low,
    };
    try self.write(next);
}

fn emit(self: *Pin, event: drivers.Gpio.Event) void {
    const callback = blk: {
        self.mutex.lock();
        defer self.mutex.unlock();
        break :blk .{
            .ctx = self.callback_ctx,
            .func = self.callback_fn,
        };
    };
    if (callback.ctx) |ctx| {
        if (callback.func) |func| func(ctx, event);
    }
}

fn edgeFromTransition(previous: drivers.Gpio.Level, current: drivers.Gpio.Level) drivers.Gpio.Edge {
    if (previous == .low and current == .high) return .rising;
    if (previous == .high and current == .low) return .falling;
    return switch (current) {
        .low => .low_level,
        .high => .high_level,
    };
}

fn shouldEmit(
    configured: ?drivers.Gpio.Edge,
    previous: drivers.Gpio.Level,
    current: drivers.Gpio.Level,
    edge: drivers.Gpio.Edge,
) bool {
    const target = configured orelse return false;
    return switch (target) {
        .rising => previous == .low and current == .high,
        .falling => previous == .high and current == .low,
        .both => previous != current,
        .low_level => current == .low,
        .high_level => current == .high,
    } and switch (edge) {
        .rising, .falling, .low_level, .high_level => true,
        .both => false,
    };
}

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const TestCase = struct {
        const Sink = struct {
            calls: usize = 0,
            last_event: ?drivers.Gpio.Event = null,

            fn emit(ctx: *const anyopaque, event: drivers.Gpio.Event) void {
                const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
                self.calls += 1;
                self.last_event = event;
            }
        };

        fn writeUpdatesLevelAndEmitsConfiguredEdge() !void {
            var pin = Pin.init(.low);
            var sink = Sink{};
            const gpio = pin.handle();

            try gpio.configureInterrupt(.rising);
            gpio.setEventCallback(@ptrCast(&sink), Sink.emit);
            try gpio.write(.high);

            try std.testing.expectEqual(drivers.Gpio.Level.high, try gpio.read());
            try std.testing.expectEqual(@as(usize, 1), sink.calls);
            try std.testing.expectEqual(drivers.Gpio.Edge.rising, sink.last_event.?.edge);
            try std.testing.expectEqual(drivers.Gpio.Level.high, sink.last_event.?.level);
        }

        fn clearCallbackStopsEmission() !void {
            var pin = Pin.init(.low);
            var sink = Sink{};
            const gpio = pin.handle();

            try gpio.configureInterrupt(.both);
            gpio.setEventCallback(@ptrCast(&sink), Sink.emit);
            gpio.clearEventCallback();
            try gpio.write(.high);

            try std.testing.expectEqual(@as(usize, 0), sink.calls);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.writeUpdatesLevelAndEmitsConfiguredEdge() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.clearCallbackStopsEmission() catch |err| {
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
