//! I2C HAL contract wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    InitFailed,
    NoAck,
    Timeout,
    ArbitrationLost,
    InvalidParam,
    Busy,
    I2cError,
};

pub const Config = struct {
    sda: u8,
    scl: u8,
    freq_hz: u32 = 400_000,
    port: u8 = 0,
    pullup_en: bool = true,
    timeout_ms: u32 = 1000,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .i2c;
}

/// spec must define:
/// - Driver: implementing `write` and `writeRead`
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        _ = @as(*const fn (*BaseDriver, u7, []const u8) Error!void, &BaseDriver.write);
        _ = @as(*const fn (*BaseDriver, u7, []const u8, []u8) Error!void, &BaseDriver.writeRead);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .i2c,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn write(self: *Self, address: u7, data: []const u8) Error!void {
            return self.driver.write(address, data);
        }

        pub fn writeRead(self: *Self, address: u7, write_data: []const u8, read_buf: []u8) Error!void {
            return self.driver.writeRead(address, write_data, read_buf);
        }
    };
}

test "i2c wrapper" {
    const Mock = struct {
        pub fn write(_: *@This(), _: u7, _: []const u8) Error!void {}
        pub fn writeRead(_: *@This(), _: u7, _: []const u8, out: []u8) Error!void {
            if (out.len > 0) out[0] = 0x42;
        }
    };

    const Dev = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "i2c.test" };
    });

    var d = Mock{};
    var bus = Dev.init(&d);
    var out: [1]u8 = .{0};
    try bus.write(0x50, &[_]u8{0x00});
    try bus.writeRead(0x50, &[_]u8{0x00}, &out);
    try @import("std").testing.expectEqual(@as(u8, 0x42), out[0]);
}
