//! UART HAL wrapper.

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const Error = error{
    WouldBlock,
    Timeout,
    Framing,
    Parity,
    Overflow,
    UartError,
};

pub const PollFlags = packed struct {
    readable: bool = false,
    writable: bool = false,
    _padding: u6 = 0,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .uart;
}

/// spec must define:
/// - Driver.read(*Driver, []u8) Error!usize
/// - Driver.write(*Driver, []const u8) Error!usize
/// - Driver.poll(*Driver, PollFlags, i32) PollFlags
/// - meta.id
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver, []u8) Error!usize, &BaseDriver.read);
        _ = @as(*const fn (*BaseDriver, []const u8) Error!usize, &BaseDriver.write);
        _ = @as(*const fn (*BaseDriver, PollFlags, i32) PollFlags, &BaseDriver.poll);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .uart,
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

test "uart wrapper" {
    const Mock = struct {
        tx: [16]u8 = [_]u8{0} ** 16,
        tx_len: usize = 0,
        rx: [16]u8 = [_]u8{ 'O', 'K', 0 } ++ [_]u8{0} ** 13,
        rx_len: usize = 2,

        pub fn read(self: *@This(), buf: []u8) Error!usize {
            if (self.rx_len == 0) return error.WouldBlock;
            const n = @min(buf.len, self.rx_len);
            @memcpy(buf[0..n], self.rx[0..n]);
            self.rx_len = 0;
            return n;
        }
        pub fn write(self: *@This(), buf: []const u8) Error!usize {
            const n = @min(buf.len, self.tx.len);
            @memcpy(self.tx[0..n], buf[0..n]);
            self.tx_len = n;
            return n;
        }
        pub fn poll(self: *@This(), flags: PollFlags, _: i32) PollFlags {
            return .{ .readable = flags.readable and self.rx_len > 0, .writable = flags.writable };
        }
    };

    const Uart = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "uart.test" };
    });

    var d = Mock{};
    var uart = Uart.init(&d);

    const out = [_]u8{ 'H', 'i' };
    _ = try uart.write(&out);
    try std.testing.expectEqual(@as(usize, 2), d.tx_len);

    var in: [4]u8 = undefined;
    const n = try uart.read(&in);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "OK", in[0..2]);
}
