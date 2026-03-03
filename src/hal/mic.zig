//! Microphone HAL wrapper.

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const Error = error{
    WouldBlock,
    Timeout,
    Overflow,
    InvalidState,
    MicError,
};

pub const SampleFormat = enum {
    s16,
    s32,
    f32,
};

pub const Config = struct {
    sample_rate: u32 = 16000,
    channels: u8 = 1,
    bits_per_sample: u8 = 16,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .mic;
}

/// spec must define:
/// - Driver.read(*Driver, []i16) !usize
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    const has_spec_config = comptime @hasDecl(spec, "config");

    comptime {
        _ = @as(*const fn (*BaseDriver, []i16) Error!usize, &BaseDriver.read);
        _ = @as(*const fn (*BaseDriver, i8) Error!void, &BaseDriver.setGain);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.start);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.stop);

        _ = @as([]const u8, spec.meta.id);
        if (has_spec_config) {
            _ = @as(Config, spec.config);
            if (spec.config.sample_rate == 0) {
                @compileError("mic config.sample_rate must be > 0");
            }
        }
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .mic,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const config: Config = if (has_spec_config) spec.config else .{};

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn read(self: *Self, buffer: []i16) Error!usize {
            return self.driver.read(buffer);
        }

        pub fn setGain(self: *Self, gain_db: i8) Error!void {
            return self.driver.setGain(gain_db);
        }

        pub fn start(self: *Self) Error!void {
            return self.driver.start();
        }

        pub fn stop(self: *Self) Error!void {
            return self.driver.stop();
        }

        pub fn supportsGain() bool {
            return true;
        }

        pub fn supportsStartStop() bool {
            return true;
        }

        pub fn samplesForMs(duration_ms: u32) u32 {
            return config.sample_rate * duration_ms / 1000;
        }

        pub fn msForSamples(samples: u32) u32 {
            return samples * 1000 / config.sample_rate;
        }
    };
}

test "mic wrapper" {
    const MockDriver = struct {
        sample_value: i16 = 1234,

        pub fn read(self: *@This(), buffer: []i16) Error!usize {
            for (buffer) |*s| s.* = self.sample_value;
            return buffer.len;
        }

        pub fn setGain(_: *@This(), _: i8) Error!void {}
        pub fn start(_: *@This()) Error!void {}
        pub fn stop(_: *@This()) Error!void {}
    };

    const Mic = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "mic.test" };
        pub const config = Config{ .sample_rate = 16000 };
    });

    var d = MockDriver{};
    var mic = Mic.init(&d);

    var buffer: [16]i16 = undefined;
    const n = try mic.read(&buffer);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqual(@as(i16, 1234), buffer[0]);
    try std.testing.expect(Mic.supportsGain());
    try std.testing.expectEqual(@as(u32, 160), Mic.samplesForMs(10));
}
