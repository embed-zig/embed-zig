//! Runtime Network Interface Contract

const std = @import("std");

pub const Ipv4Address = [4]u8;
pub const MacAddress = [6]u8;
pub const IfName = [16]u8;

pub const State = enum {
    down,
    up,
    connected,
};

pub const DhcpMode = enum {
    disabled,
    client,
    server,
};

pub const types = struct {
    pub const DnsServers = struct {
        primary: Ipv4Address,
        secondary: Ipv4Address,
    };
};

pub const Info = struct {
    name: IfName = std.mem.zeroes(IfName),
    name_len: u8 = 0,
    mac: MacAddress = std.mem.zeroes(MacAddress),
    state: State = .down,
    dhcp: DhcpMode = .disabled,
    ip: Ipv4Address = .{ 0, 0, 0, 0 },
    netmask: Ipv4Address = .{ 0, 0, 0, 0 },
    gateway: Ipv4Address = .{ 0, 0, 0, 0 },
    dns_main: Ipv4Address = .{ 0, 0, 0, 0 },
    dns_backup: Ipv4Address = .{ 0, 0, 0, 0 },

    pub fn getName(self: *const Info) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Route = struct {
    dest: Ipv4Address = .{ 0, 0, 0, 0 },
    mask: Ipv4Address = .{ 0, 0, 0, 0 },
    gateway: Ipv4Address = .{ 0, 0, 0, 0 },
    iface: IfName = std.mem.zeroes(IfName),
    iface_len: u8 = 0,
    metric: u16 = 0,
};

/// NetIf contract:
/// - `list(self) -> []const IfName`
/// - `get(self, name: IfName) -> ?Info`
/// - `getDefault(self) -> ?IfName`
/// - `setDefault(self, name: IfName) -> void`
/// - `up(self, name: IfName) -> void`
/// - `down(self, name: IfName) -> void`
/// - `getDns(self) -> types.DnsServers`
/// - `setDns(self, primary: Ipv4Address, secondary: ?Ipv4Address) -> void`
/// - `addRoute(self, route: Route) -> void`
/// - `delRoute(self, dest: Ipv4Address, mask: Ipv4Address) -> void`
pub fn from(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (Impl) []const IfName, &Impl.list);
        _ = @as(*const fn (Impl, IfName) ?Info, &Impl.get);
        _ = @as(*const fn (Impl) ?IfName, &Impl.getDefault);
        _ = @as(*const fn (Impl, IfName) void, &Impl.setDefault);
        _ = @as(*const fn (Impl, IfName) void, &Impl.up);
        _ = @as(*const fn (Impl, IfName) void, &Impl.down);
        _ = @as(*const fn (Impl) types.DnsServers, &Impl.getDns);
        _ = @as(*const fn (Impl, Ipv4Address, ?Ipv4Address) void, &Impl.setDns);
        _ = @as(*const fn (Impl, Route) void, &Impl.addRoute);
        _ = @as(*const fn (Impl, Ipv4Address, Ipv4Address) void, &Impl.delRoute);
    }
    return Impl;
}

pub fn ifName(name: []const u8) IfName {
    var out: IfName = std.mem.zeroes(IfName);
    const n = @min(name.len, out.len);
    @memcpy(out[0..n], name[0..n]);
    return out;
}
