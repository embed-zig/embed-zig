//! ADC Button — multi-button input via single ADC channel.
//!
//! Generic over EventType and tag. Polls an ADC channel through a worker
//! thread. Multiple buttons share one channel via a resistor ladder; each
//! button maps to a voltage range.
//!
//! Only emits press/release events. When the voltage jumps from one button
//! range to another without returning to ref, a release for the old button
//! and a press for the new button are emitted back-to-back.

const std = @import("std");
const runtime = struct {
    pub const io = @import("../../../../runtime/io.zig");
};
const hal = struct {
    pub const adc = @import("../../../../hal/adc.zig");
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

pub const Range = struct {
    id: []const u8,
    min_mv: u16,
    max_mv: u16,
};

pub const Config = struct {
    ranges: []const Range,
    adc_channel: u8 = 0,
    ref_value_mv: u32 = 3300,
    ref_tolerance_mv: u32 = 200,
    poll_interval_ms: u32 = 10,
    debounce_samples: u8 = 3,
    thread_stack_size: usize = 4096,
};

pub fn AdcButtonSet(
    comptime Adc: type,
    comptime Thread: type,
    comptime Time: type,
    comptime IO: type,
    comptime EventType: type,
    comptime tag: []const u8,
) type {
    comptime {
        if (!hal.adc.is(Adc)) @compileError("Adc must be a hal.adc type");
        _ = runtime.io.from(IO);
        event_pkg.types.assertTaggedUnion(EventType);
    }

    const fd_t = runtime.io.fd_t;
    const PeriphType = event_pkg.Periph(EventType);

    return struct {
        const Self = @This();

        periph: PeriphType,
        adc: *Adc,
        io: *IO,
        time: Time,
        config: Config,
        worker: ?Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        ch_r: fd_t,
        ch_w: fd_t,

        current_button: ?usize = null,
        stable_count: u8 = 0,
        pending_button: ?usize = null,

        const WireEvent = extern struct {
            code: u16,
            range_idx: u16,
        };

        pub fn init(adc: *Adc, io: *IO, time: Time, config: Config) !Self {
            const ch = try io.createChannel();

            return .{
                .periph = undefined,
                .adc = adc,
                .io = io,
                .time = time,
                .config = config,
                .ch_r = ch.read_fd,
                .ch_w = ch.write_fd,
            };
        }

        pub fn bind(self: *Self) void {
            self.periph = .{ .ctx = self, .fd = self.ch_r, .onReady = onReady };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.io.closeChannel(self.ch_r);
            self.io.closeChannel(self.ch_w);
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
            const mv: u32 = self.adc.readMv(self.config.adc_channel) catch return;
            const detected = self.findButton(mv);

            if (detected == self.pending_button) {
                self.stable_count +|= 1;
            } else {
                self.pending_button = detected;
                self.stable_count = 1;
            }

            if (self.stable_count < self.config.debounce_samples) return;

            if (detected == self.current_button) return;

            if (self.current_button) |old| {
                self.sendEvent(.release, old);
            }

            self.current_button = detected;

            if (detected) |new| {
                self.sendEvent(.press, new);
            }
        }

        fn findButton(self: *const Self, mv: u32) ?usize {
            if (self.isRefValue(mv)) return null;
            for (self.config.ranges, 0..) |range, i| {
                if (mv >= range.min_mv and mv <= range.max_mv) {
                    return i;
                }
            }
            return null;
        }

        fn isRefValue(self: *const Self, mv: u32) bool {
            const ref = self.config.ref_value_mv;
            const tol = self.config.ref_tolerance_mv;
            return mv >= ref -| tol and mv <= ref +| tol;
        }

        fn sendEvent(self: *Self, code: BusButtonCode, range_idx: usize) void {
            const wire = WireEvent{
                .code = @intFromEnum(code),
                .range_idx = @intCast(range_idx),
            };
            _ = self.io.writeChannel(self.ch_w, std.mem.asBytes(&wire)) catch {};
        }

        fn onReady(ctx: ?*anyopaque, _: fd_t, buf: *std.ArrayList(EventType), alloc: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            var wire: WireEvent = undefined;
            const wire_bytes = std.mem.asBytes(&wire);
            while (true) {
                const n = self.io.readChannel(self.ch_r, wire_bytes) catch break;
                if (n < wire_bytes.len) break;
                if (wire.range_idx >= self.config.ranges.len) continue;
                buf.append(alloc, @unionInit(EventType, tag, .{
                    .id = self.config.ranges[wire.range_idx].id,
                    .code = wire.code,
                    .data = 0,
                })) catch {};
            }
        }
    };
}
