//! HCI Transport HAL Component.

const std = @import("std");
const hal_marker = @import("marker.zig");

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .hci;
}

pub const PollFlags = packed struct {
    readable: bool = false,
    writable: bool = false,
    _padding: u6 = 0,
};

pub const PacketType = enum(u8) {
    command = 0x01,
    acl_data = 0x02,
    sync_data = 0x03,
    event = 0x04,
    iso_data = 0x05,
};

pub const Error = error{
    WouldBlock,
    HciError,
};

/// spec must define:
/// - Driver.read(*Driver, []u8) Error!usize
/// - Driver.write(*Driver, []const u8) Error!usize
/// - Driver.poll(*Driver, PollFlags, i32) PollFlags
/// - meta.id
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };

        _ = @as(*const fn (*BaseDriver, []u8) Error!usize, &BaseDriver.read);
        _ = @as(*const fn (*BaseDriver, []const u8) Error!usize, &BaseDriver.write);
        _ = @as(*const fn (*BaseDriver, PollFlags, i32) PollFlags, &BaseDriver.poll);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .hci,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn read(self: *Self, buf: []u8) Error!usize {
            return self.driver.read(buf);
        }

        pub fn write(self: *Self, buf: []const u8) Error!usize {
            return self.driver.write(buf);
        }

        pub fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags {
            return self.driver.poll(flags, timeout_ms);
        }
    };
}

test "hci wrapper basic" {
    const MockDriver = struct {
        const Self = @This();

        rx_buf: [8]u8 = .{ 0x04, 0x0E, 0x01, 0x00, 0, 0, 0, 0 },
        rx_len: usize = 4,
        tx_buf: [8]u8 = .{0} ** 8,

        pub fn read(self: *Self, buf: []u8) Error!usize {
            if (self.rx_len == 0) return error.WouldBlock;
            const n = @min(self.rx_len, buf.len);
            @memcpy(buf[0..n], self.rx_buf[0..n]);
            self.rx_len = 0;
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) Error!usize {
            const n = @min(buf.len, self.tx_buf.len);
            @memcpy(self.tx_buf[0..n], buf[0..n]);
            return n;
        }

        pub fn poll(self: *Self, flags: PollFlags, _: i32) PollFlags {
            return .{
                .readable = flags.readable and self.rx_len > 0,
                .writable = flags.writable,
            };
        }
    };

    const Hci = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "hci.test" };
    });

    var d = MockDriver{};
    var hci = Hci.init(&d);

    try std.testing.expect(hci.poll(.{ .readable = true }, 0).readable);

    var buf: [8]u8 = undefined;
    const n = try hci.read(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PacketType.event)), buf[0]);

    const cmd = [_]u8{ @intFromEnum(PacketType.command), 0x03, 0x0C, 0x00 };
    _ = try hci.write(&cmd);
    try std.testing.expectEqualSlices(u8, &cmd, d.tx_buf[0..cmd.len]);
}
