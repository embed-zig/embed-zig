//! GPIO button — polls a pin, writes press/release events to a channel
//! that the event bus can multiplex.
//!
//! The caller is responsible for running the polling loop. Call `run()`
//! from a dedicated thread/task; call `requestStop()` to exit the loop.

const std = @import("std");
const runtime = struct {
    pub const io = @import("../../../../runtime/io.zig");
};
const hal = struct {
    pub const gpio = @import("../../../../hal/gpio.zig");
};
const event_pkg = struct {
    pub const types = @import("../../types.zig");

    pub fn Periph(comptime EventType: type) type {
        return @import("../../bus.zig").Periph(EventType);
    }
};

pub const BusButtonCode = enum(u16) {
    press = 1,
    release = 2,
};

pub const Level = hal.gpio.Level;

pub const Config = struct {
    id: []const u8 = "button",
    pin: u8,
    active_level: Level = .high,
    debounce_ms: u32 = 20,
    poll_interval_ms: u32 = 10,
};

pub fn Button(
    comptime Gpio: type,
    comptime Time: type,
    comptime IO: type,
    comptime EventType: type,
    comptime tag: []const u8,
) type {
    comptime {
        if (!hal.gpio.is(Gpio)) @compileError("Gpio must be a hal.gpio type");
        _ = runtime.io.from(IO);
        event_pkg.types.assertTaggedUnion(EventType);
    }

    const fd_t = runtime.io.fd_t;
    const PeriphType = event_pkg.Periph(EventType);

    return struct {
        const Self = @This();

        periph: PeriphType,
        gpio: *Gpio,
        io: *IO,
        time: Time,
        config: Config,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pipe_r: fd_t,
        pipe_w: fd_t,

        state: State = .idle,
        last_raw: bool = false,
        debounce_start_ms: u64 = 0,
        pressed: bool = false,

        const State = enum { idle, debouncing };

        const WireEvent = extern struct {
            code: u16,
        };

        pub fn init(gpio: *Gpio, io: *IO, time: Time, config: Config) !Self {
            const ch = try io.createChannel();

            return .{
                .periph = undefined,
                .gpio = gpio,
                .io = io,
                .time = time,
                .config = config,
                .pipe_r = ch.read_fd,
                .pipe_w = ch.write_fd,
            };
        }

        pub fn bind(self: *Self) void {
            self.periph = .{ .ctx = self, .fd = self.pipe_r, .onReady = onReady };
        }

        pub fn deinit(self: *Self) void {
            self.requestStop();
            self.io.closeChannel(self.pipe_r);
            self.io.closeChannel(self.pipe_w);
        }

        /// Blocking polling loop. Call from a dedicated thread/task.
        /// Returns when `requestStop()` is called.
        pub fn run(self: *Self) void {
            self.running.store(true, .release);
            defer self.running.store(false, .release);

            while (self.running.load(.acquire)) {
                self.tick();
                self.time.sleepMs(self.config.poll_interval_ms);
            }
        }

        /// Convenience: `run` as a `fn(?*anyopaque) void` for Thread.spawn.
        pub fn runFromCtx(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            self.run();
        }

        pub fn requestStop(self: *Self) void {
            self.running.store(false, .release);
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
        }

        fn tick(self: *Self) void {
            const now_ms = self.time.nowMs();
            const raw = self.readRawPressed();

            switch (self.state) {
                .idle => {
                    if (raw != self.last_raw) {
                        self.state = .debouncing;
                        self.debounce_start_ms = now_ms;
                    }
                },
                .debouncing => {
                    if (now_ms >= self.debounce_start_ms + self.config.debounce_ms) {
                        if (raw != self.pressed) {
                            self.pressed = raw;
                            self.sendEvent(if (raw) .press else .release);
                        }
                        self.state = .idle;
                    }
                },
            }

            self.last_raw = raw;
        }

        fn readRawPressed(self: *Self) bool {
            const lv = self.gpio.getLevel(self.config.pin) catch return self.pressed;
            return lv == self.config.active_level;
        }

        fn sendEvent(self: *Self, code: BusButtonCode) void {
            const wire = WireEvent{ .code = @intFromEnum(code) };
            _ = self.io.writeChannel(self.pipe_w, std.mem.asBytes(&wire)) catch {};
        }

        fn onReady(ctx: ?*anyopaque, _: fd_t, buf: *std.ArrayList(EventType), alloc: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            var wire: WireEvent = undefined;
            const wire_bytes = std.mem.asBytes(&wire);
            while (true) {
                const n = self.io.readChannel(self.pipe_r, wire_bytes) catch break;
                if (n < wire_bytes.len) break;
                buf.append(alloc, @unionInit(EventType, tag, .{
                    .id = self.config.id,
                    .code = wire.code,
                    .data = 0,
                })) catch {};
            }
        }
    };
}
