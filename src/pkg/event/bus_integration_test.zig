//! Integration test & usage example for the event system.
//!
//! Demonstrates the complete pipeline an application would use:
//!
//!   1. Define your own EventType union(enum)
//!   2. Create a Bus(IO, EventType)
//!   3. Register peripherals (button, motion sensor, ...)
//!   4. Optionally add middleware (gesture recognition, ...)
//!   5. while (running) { bus.poll() → switch on events }

const std = @import("std");
const testing = std.testing;
const runtime_std = @import("../../runtime/std.zig");
const event_types = @import("types.zig");
const event_bus = @import("bus.zig");
const event_motion_types = @import("motion/types.zig");
const event_button_gesture = @import("button/gesture.zig");
const event_timer_mod = @import("timer/timer.zig");

const GestureCode = event_button_gesture.GestureCode;
const MotionAction = event_motion_types.MotionAction(true);
const TimerPayload = event_timer_mod.TimerPayload;
const StdIO = runtime_std.IO;
const fd_t = event_bus.fd_t;

// =========================================================================
// Step 1: Application defines its own event type
// =========================================================================

const AppEvent = union(enum) {
    button: event_types.PeriphEvent,
    motion: MotionAction,
    timer: TimerPayload,
    system: event_types.SystemEvent,
};

const AppBus = event_bus.Bus(StdIO, AppEvent);

// =========================================================================
// Fake time — deterministic for tests
// =========================================================================

const FakeTime = struct {
    ms: u64 = 0,

    pub fn nowMs(self: *const FakeTime) u64 {
        return self.ms;
    }

    pub fn sleepMs(_: *const FakeTime, _: u32) void {}
};

// =========================================================================
// Pipe-based test peripherals (simulate real devices via pipes)
// =========================================================================

fn PipeSource(comptime EventType: type, comptime WireType: type) type {
    return struct {
        const Self = @This();

        pipe_r: fd_t,
        pipe_w: fd_t,
        periph: event_bus.Periph(EventType),
        ctx_data: CtxData,

        const CtxData = struct {
            pipe_r: fd_t,
            buildEvent: *const fn (wire: WireType) EventType,
        };

        fn open(buildEvent: *const fn (wire: WireType) EventType) !Self {
            const fds = try std.posix.pipe();
            try setNonBlocking(fds[0]);
            try setNonBlocking(fds[1]);
            return .{
                .pipe_r = fds[0],
                .pipe_w = fds[1],
                .periph = undefined,
                .ctx_data = .{ .pipe_r = fds[0], .buildEvent = buildEvent },
            };
        }

        fn bind(self: *Self) void {
            self.periph = .{
                .ctx = &self.ctx_data,
                .fd = self.pipe_r,
                .onReady = onReady,
            };
        }

        fn close(self: *Self) void {
            std.posix.close(self.pipe_r);
            std.posix.close(self.pipe_w);
        }

        fn send(self: *Self, wire: WireType) void {
            _ = std.posix.write(self.pipe_w, std.mem.asBytes(&wire)) catch {};
        }

        fn onReady(ctx: ?*anyopaque, _: fd_t, buf: *std.ArrayList(EventType), alloc: std.mem.Allocator) void {
            const data: *const CtxData = @ptrCast(@alignCast(ctx orelse return));
            var wire: WireType = undefined;
            const wire_bytes = std.mem.asBytes(&wire);
            while (true) {
                const n = std.posix.read(data.pipe_r, wire_bytes) catch break;
                if (n < wire_bytes.len) break;
                buf.append(alloc, data.buildEvent(wire)) catch {};
            }
        }

        fn setNonBlocking(fd_val: fd_t) !void {
            var fl = try std.posix.fcntl(fd_val, std.posix.F.GETFL, 0);
            const mask: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
            fl |= mask;
            _ = try std.posix.fcntl(fd_val, std.posix.F.SETFL, fl);
        }
    };
}

const ButtonWire = extern struct { code: u16 };

fn buildButtonEvent(wire: ButtonWire) AppEvent {
    return .{ .button = .{ .id = "btn.ok", .code = wire.code, .data = 0 } };
}

fn buildMotionEvent(action: MotionAction) AppEvent {
    return .{ .motion = action };
}

const TimerWire = extern struct { count: u32 };

fn buildTimerEvent(wire: TimerWire) AppEvent {
    return .{ .timer = .{ .id = "tick.1s", .count = wire.count, .interval_ms = 1000 } };
}

const ButtonSource = PipeSource(AppEvent, ButtonWire);
const MotionSource = PipeSource(AppEvent, MotionAction);
const TimerPipeSource = PipeSource(AppEvent, TimerWire);

// =========================================================================
// Example: full pipeline — bus + button + motion + timer + gesture
// =========================================================================

test "example: complete event pipeline with button, motion, timer, and gesture" {
    // -- init IO and bus --
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = AppBus.init(testing.allocator, &io);
    defer bus.deinit();

    // -- register gesture middleware (press/release → click with count) --
    var time = FakeTime{ .ms = 0 };
    const Gesture = event_button_gesture.ButtonGesture(AppEvent, "button", *FakeTime);
    var gesture = Gesture.init(&time, .{
        .multi_click_window_ms = 200,
        .long_press_ms = 500,
    });
    bus.use(gesture.middleware());

    // -- register button peripheral --
    var btn = try ButtonSource.open(buildButtonEvent);
    defer btn.close();
    btn.bind();
    try bus.register(&btn.periph);

    // -- register motion peripheral --
    var imu = try MotionSource.open(buildMotionEvent);
    defer imu.close();
    imu.bind();
    try bus.register(&imu.periph);

    // -- register timer peripheral --
    var tmr = try TimerPipeSource.open(buildTimerEvent);
    defer tmr.close();
    tmr.bind();
    try bus.register(&tmr.periph);

    // -- simulate: button press + release (short tap) --
    btn.send(.{ .code = @intFromEnum(GestureCode.press) });
    time.ms = 40;
    btn.send(.{ .code = @intFromEnum(GestureCode.release) });

    // -- simulate: IMU detects a shake --
    imu.send(.{ .shake = .{ .magnitude = 2.5, .duration_ms = 200 } });

    // -- simulate: timer tick --
    tmr.send(.{ .count = 1 });

    // -- poll loop (simulates the app's main loop) --
    var out: [16]AppEvent = undefined;
    var saw_click = false;
    var saw_shake = false;
    var saw_timer = false;

    // poll 1: raw button events enter gesture middleware (buffered),
    //         motion shake and timer tick pass through immediately
    {
        const got = bus.poll(&out, 200);
        for (got) |ev| {
            switch (ev) {
                .button => |b| {
                    if (b.code == @intFromEnum(GestureCode.click)) saw_click = true;
                },
                .motion => |m| switch (m) {
                    .shake => |s| {
                        try testing.expectApproxEqAbs(@as(f32, 2.5), s.magnitude, 0.01);
                        saw_shake = true;
                    },
                    else => {},
                },
                .timer => |t| {
                    try testing.expectEqualStrings("tick.1s", t.id);
                    try testing.expectEqual(@as(u32, 1), t.count);
                    saw_timer = true;
                },
                .system => {},
            }
        }
    }

    // poll 2: advance time past click_timeout → gesture tick emits click
    time.ms = 400;
    {
        const got = bus.poll(&out, 0);
        for (got) |ev| {
            switch (ev) {
                .button => |b| {
                    if (b.code == @intFromEnum(GestureCode.click)) {
                        try testing.expectEqualStrings("btn.ok", b.id);
                        saw_click = true;
                    }
                },
                .motion => |m| switch (m) {
                    .shake => {
                        saw_shake = true;
                    },
                    else => {},
                },
                .timer => |t| {
                    _ = t;
                    saw_timer = true;
                },
                .system => {},
            }
        }
    }

    try testing.expect(saw_click);
    try testing.expect(saw_shake);
    try testing.expect(saw_timer);
}

// =========================================================================
// Example: system events pass through the full pipeline untouched
// =========================================================================

test "example: system events pass through middleware" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = AppBus.init(testing.allocator, &io);
    defer bus.deinit();

    var time = FakeTime{ .ms = 0 };
    const Gesture = event_button_gesture.ButtonGesture(AppEvent, "button", *FakeTime);
    var gesture = Gesture.init(&time, .{});
    bus.use(gesture.middleware());

    // inject a system event directly
    bus.ready.append(testing.allocator, .{ .system = .low_battery }) catch {};

    var out: [4]AppEvent = undefined;
    const got = bus.poll(&out, 0);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(AppEvent{ .system = .low_battery }, got[0]);
}

// =========================================================================
// Example: multiple button peripherals + motion on same bus
// =========================================================================

test "example: multiple peripherals on same bus" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();
    var bus = AppBus.init(testing.allocator, &io);
    defer bus.deinit();

    const buildBtnA = struct {
        fn f(wire: ButtonWire) AppEvent {
            return .{ .button = .{ .id = "btn.a", .code = wire.code, .data = 0 } };
        }
    }.f;
    const buildBtnB = struct {
        fn f(wire: ButtonWire) AppEvent {
            return .{ .button = .{ .id = "btn.b", .code = wire.code, .data = 0 } };
        }
    }.f;

    var btn_a = try ButtonSource.open(buildBtnA);
    defer btn_a.close();
    btn_a.bind();
    var btn_b = try ButtonSource.open(buildBtnB);
    defer btn_b.close();
    btn_b.bind();
    var imu = try MotionSource.open(buildMotionEvent);
    defer imu.close();
    imu.bind();

    try bus.register(&btn_a.periph);
    try bus.register(&btn_b.periph);
    try bus.register(&imu.periph);

    btn_a.send(.{ .code = 1 });
    btn_b.send(.{ .code = 2 });
    imu.send(.{ .tap = .{ .axis = .x, .count = 1, .positive = true } });

    var out: [16]AppEvent = undefined;
    const got = bus.poll(&out, 200);
    try testing.expectEqual(@as(usize, 3), got.len);
}
