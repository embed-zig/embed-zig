//! SPI HAL contract wrapper.

const hal_marker = @import("marker.zig");

pub const Error = error{
    TransferFailed,
    Busy,
    Timeout,
    SpiError,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .spi;
}

/// spec must define:
/// - Driver: write/transfer/read
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        _ = @as(*const fn (*BaseDriver, []const u8) Error!void, &BaseDriver.write);
        _ = @as(*const fn (*BaseDriver, []const u8, []u8) Error!void, &BaseDriver.transfer);
        _ = @as(*const fn (*BaseDriver, []u8) Error!void, &BaseDriver.read);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .spi,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn write(self: *Self, data: []const u8) Error!void {
            return self.driver.write(data);
        }

        pub fn transfer(self: *Self, tx: []const u8, rx: []u8) Error!void {
            return self.driver.transfer(tx, rx);
        }

        pub fn read(self: *Self, buf: []u8) Error!void {
            return self.driver.read(buf);
        }
    };
}

test "spi wrapper" {
    const Mock = struct {
        pub fn write(_: *@This(), _: []const u8) Error!void {}
        pub fn transfer(_: *@This(), tx: []const u8, rx: []u8) Error!void {
            const n = @min(tx.len, rx.len);
            @memcpy(rx[0..n], tx[0..n]);
        }
        pub fn read(_: *@This(), _: []u8) Error!void {}
    };

    const Dev = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "spi.test" };
    });

    var d = Mock{};
    var bus = Dev.init(&d);
    var rx: [3]u8 = .{ 0, 0, 0 };
    try bus.transfer(&[_]u8{ 1, 2, 3 }, &rx);
    try @import("std").testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, &rx);
}
