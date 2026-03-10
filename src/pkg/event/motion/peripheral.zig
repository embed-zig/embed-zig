//! Motion peripheral — polls an IMU via a worker thread, runs the Detector
//! algorithm, and writes detected motion actions (shake, tap, tilt, flip,
//! freefall) to a pipe fd that the event bus can multiplex.
//!
//! Generic over EventType and tag. The EventType's tag payload must be
//! compatible with the Detector's ActionType (MotionAction).

const std = @import("std");
const runtime = struct {
    pub const io = @import("../../../runtime/io.zig");
};
const hal = struct {
    pub const imu = @import("../../../hal/imu.zig");
};
const event_pkg = struct {
    pub const types = @import("../types.zig");

    pub fn Periph(comptime EventType: type) type {
        return @import("../bus.zig").Periph(EventType);
    }
};
const detector_mod = @import("detector.zig");
const motion_types = @import("types.zig");

pub const Config = struct {
    id: []const u8 = "imu",
    poll_interval_ms: u32 = 20,
    thread_stack_size: usize = 4096,
    thresholds: motion_types.Thresholds = .{},
};

pub fn MotionPeripheral(
    comptime Sensor: type,
    comptime Thread: type,
    comptime Time: type,
    comptime IO: type,
    comptime EventType: type,
    comptime tag: []const u8,
) type {
    comptime {
        if (!hal.imu.is(Sensor)) @compileError("Sensor must be a hal.imu type");
        _ = runtime.io.from(IO);
        event_pkg.types.assertTaggedUnion(EventType);
    }

    const fd_t = runtime.io.fd_t;
    const PeriphType = event_pkg.Periph(EventType);
    const Det = detector_mod.Detector(Sensor);
    const Action = Det.ActionType;
    const Sample = Det.SampleType;

    return struct {
        const Self = @This();

        periph: PeriphType,
        sensor: *Sensor,
        io: *IO,
        time: Time,
        config: Config,
        detector: Det,
        worker: ?Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pipe_r: fd_t,
        pipe_w: fd_t,

        pub fn init(sensor: *Sensor, io: *IO, time: Time, config: Config) !Self {
            const pipe_fds = try std.posix.pipe();
            errdefer {
                std.posix.close(pipe_fds[0]);
                std.posix.close(pipe_fds[1]);
            }

            try setNonBlocking(pipe_fds[0]);
            try setNonBlocking(pipe_fds[1]);

            return .{
                .periph = undefined,
                .sensor = sensor,
                .io = io,
                .time = time,
                .config = config,
                .detector = Det.init(config.thresholds),
                .pipe_r = pipe_fds[0],
                .pipe_w = pipe_fds[1],
            };
        }

        pub fn bind(self: *Self) void {
            self.periph = .{ .ctx = self, .fd = self.pipe_r, .onReady = onReady };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            std.posix.close(self.pipe_r);
            std.posix.close(self.pipe_w);
        }

        pub fn start(self: *Self) !void {
            if (self.running.load(.acquire)) return;
            self.running.store(true, .release);
            errdefer self.running.store(false, .release);
            self.worker = try Thread.spawn(
                .{ .stack_size = self.config.thread_stack_size },
                workerMain,
                @ptrCast(self),
            );
        }

        pub fn stop(self: *Self) void {
            if (!self.running.swap(false, .acq_rel)) return;
            if (self.worker) |*th| {
                th.join();
                self.worker = null;
            }
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
        }

        fn workerMain(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            while (self.running.load(.acquire)) {
                self.tick();
                self.time.sleepMs(self.config.poll_interval_ms);
            }
        }

        fn tick(self: *Self) void {
            const accel_raw = self.sensor.readAccel() catch return;
            const accel = motion_types.accelFrom(accel_raw);

            const gyro = if (Det.has_gyroscope)
                motion_types.gyroFrom(self.sensor.readGyro() catch return)
            else {};

            const sample = Sample{
                .accel = accel,
                .gyro = gyro,
                .timestamp_ms = self.time.nowMs(),
            };

            if (self.detector.update(sample)) |action| {
                self.writeAction(action);
            }
            while (self.detector.nextEvent()) |action| {
                self.writeAction(action);
            }
        }

        fn writeAction(self: *Self, action: Action) void {
            _ = std.posix.write(self.pipe_w, std.mem.asBytes(&action)) catch {};
            self.io.wake();
        }

        fn onReady(ctx: ?*anyopaque, _: fd_t, buf: *std.ArrayList(EventType), alloc: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            var action: Action = undefined;
            const action_bytes = std.mem.asBytes(&action);
            while (true) {
                const n = std.posix.read(self.pipe_r, action_bytes) catch break;
                if (n < action_bytes.len) break;
                buf.append(alloc, @unionInit(EventType, tag, action)) catch {};
            }
        }

        fn setNonBlocking(fd: fd_t) !void {
            var fl = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
            const mask: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
            fl |= mask;
            _ = try std.posix.fcntl(fd, std.posix.F.SETFL, fl);
        }
    };
}
