//! PWM HAL wrapper.

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const Error = error{
    InvalidChannel,
    InvalidDuty,
    Busy,
    Timeout,
    PwmError,
};

pub const Config = struct {
    period_ticks: u16 = 65535,
    frequency_hz: u32 = 1000,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .pwm;
}

/// spec must define:
/// - Driver.setDuty(*Driver, channel: u8, duty: u16) Error!void
/// - Driver.getDuty(*Driver, channel: u8) Error!u16
/// - Driver.setFrequency(*Driver, channel: u8, hz: u32) Error!void
/// - meta.id
///
/// optional:
/// - config: Config
pub fn from(comptime spec: type) type {
    const has_spec_config = comptime @hasDecl(spec, "config");

    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };

        _ = @as(*const fn (*BaseDriver, u8, u16) Error!void, &BaseDriver.setDuty);
        _ = @as(*const fn (*BaseDriver, u8) Error!u16, &BaseDriver.getDuty);
        _ = @as(*const fn (*BaseDriver, u8, u32) Error!void, &BaseDriver.setFrequency);

        _ = @as([]const u8, spec.meta.id);
        if (has_spec_config) {
            _ = @as(Config, spec.config);
            if (spec.config.period_ticks == 0) {
                @compileError("pwm config.period_ticks must be > 0");
            }
        }
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .pwm,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const config: Config = if (has_spec_config) spec.config else .{};

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn setDuty(self: *Self, channel: u8, duty: u16) Error!void {
            return self.driver.setDuty(channel, duty);
        }

        pub fn getDuty(self: *Self, channel: u8) Error!u16 {
            return self.driver.getDuty(channel);
        }

        pub fn setFrequency(self: *Self, channel: u8, hz: u32) Error!void {
            return self.driver.setFrequency(channel, hz);
        }

        pub fn setPercent(self: *Self, channel: u8, percent: u8) Error!void {
            const p = @min(percent, 100);
            const duty: u16 = @intCast((@as(u32, config.period_ticks) * p) / 100);
            return self.setDuty(channel, duty);
        }

        pub fn getPercent(self: *Self, channel: u8) Error!u8 {
            const duty = try self.getDuty(channel);
            return @intCast((@as(u32, duty) * 100) / config.period_ticks);
        }
    };
}

test "pwm wrapper" {
    const Mock = struct {
        duty: [4]u16 = [_]u16{0} ** 4,
        freq: [4]u32 = [_]u32{0} ** 4,

        pub fn setDuty(self: *@This(), channel: u8, duty: u16) Error!void {
            self.duty[channel] = duty;
        }
        pub fn getDuty(self: *@This(), channel: u8) Error!u16 {
            return self.duty[channel];
        }
        pub fn setFrequency(self: *@This(), channel: u8, hz: u32) Error!void {
            self.freq[channel] = hz;
        }
    };

    const Pwm = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "pwm.test" };
        pub const config = Config{ .period_ticks = 1000, .frequency_hz = 1000 };
    });

    var d = Mock{};
    var pwm = Pwm.init(&d);
    try pwm.setPercent(0, 50);
    try std.testing.expectEqual(@as(u16, 500), try pwm.getDuty(0));
    try pwm.setFrequency(0, 2000);
    try std.testing.expectEqual(@as(u32, 2000), d.freq[0]);
}
