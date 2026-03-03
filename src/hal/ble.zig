//! BLE Host HAL Component.

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const Error = error{
    Busy,
    InvalidState,
    InvalidParam,
    Timeout,
    BleError,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .ble;
}

pub const State = enum {
    uninitialized,
    idle,
    advertising,
    scanning,
    connecting,
    connected,
};

pub const Role = enum(u8) {
    central = 0x00,
    peripheral = 0x01,
};

pub const ConnectionInfo = struct {
    conn_handle: u16,
    peer_addr: [6]u8,
    peer_addr_type: u8,
    role: Role,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const DisconnectionInfo = struct {
    conn_handle: u16,
    reason: u8,
};

pub const BleEvent = union(enum) {
    advertising_started: void,
    advertising_stopped: void,
    connected: ConnectionInfo,
    disconnected: DisconnectionInfo,
    connection_failed: void,
};

pub const AdvConfig = struct {
    interval_min: u16 = 0x0800,
    interval_max: u16 = 0x0800,
    adv_data: []const u8 = &.{},
    scan_rsp_data: []const u8 = &.{},
    channel_map: u8 = 0x07,
};

/// spec must define required Driver methods:
/// start/stop/startAdvertising/stopAdvertising/poll/getState
/// disconnect/notify/indicate/getConnHandle
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.start);
        _ = @as(*const fn (*BaseDriver) void, &BaseDriver.stop);
        _ = @as(*const fn (*BaseDriver, AdvConfig) Error!void, &BaseDriver.startAdvertising);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.stopAdvertising);
        _ = @as(*const fn (*BaseDriver, i32) ?BleEvent, &BaseDriver.poll);
        _ = @as(*const fn (*const BaseDriver) State, &BaseDriver.getState);
        _ = @as(*const fn (*BaseDriver, u16, u8) Error!void, &BaseDriver.disconnect);
        _ = @as(*const fn (*BaseDriver, u16, u16, []const u8) void, &BaseDriver.notify);
        _ = @as(*const fn (*BaseDriver, u16, u16, []const u8) void, &BaseDriver.indicate);
        _ = @as(*const fn (*const BaseDriver) ?u16, &BaseDriver.getConnHandle);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .ble,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn start(self: *Self) Error!void {
            return self.driver.start();
        }

        pub fn stop(self: *Self) void {
            self.driver.stop();
        }

        pub fn startAdvertising(self: *Self, config: AdvConfig) Error!void {
            return self.driver.startAdvertising(config);
        }

        pub fn stopAdvertising(self: *Self) Error!void {
            return self.driver.stopAdvertising();
        }

        pub fn poll(self: *Self, timeout_ms: i32) ?BleEvent {
            return self.driver.poll(timeout_ms);
        }

        pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) Error!void {
            return self.driver.disconnect(conn_handle, reason);
        }

        pub fn notify(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void {
            self.driver.notify(conn_handle, attr_handle, value);
        }

        pub fn indicate(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void {
            self.driver.indicate(conn_handle, attr_handle, value);
        }

        pub fn getState(self: *const Self) State {
            return self.driver.getState();
        }

        pub fn getConnHandle(self: *const Self) ?u16 {
            return self.driver.getConnHandle();
        }
    };
}

test "ble wrapper" {
    const Mock = struct {
        state: State = .idle,

        pub fn start(self: *@This()) Error!void {
            self.state = .idle;
        }
        pub fn stop(self: *@This()) void {
            self.state = .uninitialized;
        }
        pub fn startAdvertising(self: *@This(), _: AdvConfig) Error!void {
            self.state = .advertising;
        }
        pub fn stopAdvertising(self: *@This()) Error!void {
            self.state = .idle;
        }
        pub fn poll(_: *@This(), _: i32) ?BleEvent {
            return null;
        }
        pub fn getState(self: *const @This()) State {
            return self.state;
        }
        pub fn disconnect(_: *@This(), _: u16, _: u8) Error!void {}
        pub fn notify(_: *@This(), _: u16, _: u16, _: []const u8) void {}
        pub fn indicate(_: *@This(), _: u16, _: u16, _: []const u8) void {}
        pub fn getConnHandle(_: *const @This()) ?u16 {
            return 1;
        }
    };

    const Ble = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "ble.test" };
    });

    var d = Mock{};
    var ble = Ble.init(&d);
    try ble.start();
    try std.testing.expectEqual(State.idle, ble.getState());
    try ble.startAdvertising(.{});
    try std.testing.expectEqual(State.advertising, ble.getState());
    try ble.stopAdvertising();
    try std.testing.expectEqual(State.idle, ble.getState());
}
