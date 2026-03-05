const std = @import("std");
const esp = @import("esp");
const runtime = @import("runtime");

const netif_api = esp.esp_netif.netif;
const IfName = runtime.netif.IfName;
const Info = runtime.netif.Info;
const Route = runtime.netif.Route;
const Ipv4Address = runtime.netif.Ipv4Address;
const DnsServers = runtime.netif.types.DnsServers;

pub const NetIf = struct {
    const MaxIfs = 8;
    const MaxRoutes = 16;

    var cached_names: [MaxIfs]IfName = undefined;
    var cached_count: usize = 0;
    var routes: [MaxRoutes]Route = undefined;
    var route_count: usize = 0;

    pub fn list(_: NetIf) []const IfName {
        cached_count = 0;
        var it: netif_api.Handle = null;
        it = netif_api.nextNetif(it);
        while (it != null) : (it = netif_api.nextNetif(it)) {
            if (cached_count >= MaxIfs) break;
            if (netif_api.getImplName(it)) |name_buf| {
                var ifn: IfName = std.mem.zeroes(IfName);
                var len: usize = 0;
                while (len < name_buf.len and name_buf[len] != 0) : (len += 1) {}
                const n = @min(len, ifn.len);
                @memcpy(ifn[0..n], name_buf[0..n]);
                cached_names[cached_count] = ifn;
                cached_count += 1;
            } else |_| {}
        }
        return cached_names[0..cached_count];
    }

    pub fn get(_: NetIf, name: IfName) ?Info {
        const handle = findHandle(name) orelse return null;

        var info = Info{};
        info.name = name;
        info.name_len = ifNameLen(name);

        if (netif_api.getIpInfo(handle)) |ip| {
            info.ip = netif_api.ip4ToBytes(ip.ip);
            info.netmask = netif_api.ip4ToBytes(ip.netmask);
            info.gateway = netif_api.ip4ToBytes(ip.gw);
            info.state = if (ip.ip != 0) .connected else .up;
        } else |_| {
            info.state = .down;
        }

        if (netif_api.isDhcpClient(handle)) |is_dhcp| {
            if (is_dhcp) info.dhcp = .client;
        } else |_| {}

        if (netif_api.getDnsInfo(handle, .main)) |dns| {
            info.dns_main = dns;
        } else |_| {}
        if (netif_api.getDnsInfo(handle, .backup)) |dns| {
            info.dns_backup = dns;
        } else |_| {}

        return info;
    }

    pub fn getDefault(_: NetIf) ?IfName {
        var it: netif_api.Handle = null;
        it = netif_api.nextNetif(it);
        if (it != null) {
            if (netif_api.getImplName(it)) |name_buf| {
                return toIfName(&name_buf);
            } else |_| {}
        }
        return null;
    }

    pub fn setDefault(_: NetIf, name: IfName) void {
        if (findHandle(name)) |handle| {
            netif_api.setDefaultNetif(handle);
        }
    }

    pub fn up(_: NetIf, _: IfName) void {}

    pub fn down(_: NetIf, _: IfName) void {}

    pub fn getDns(_: NetIf) DnsServers {
        var primary: Ipv4Address = .{ 0, 0, 0, 0 };
        var secondary: Ipv4Address = .{ 0, 0, 0, 0 };

        var it: netif_api.Handle = null;
        it = netif_api.nextNetif(it);
        if (it != null) {
            if (netif_api.getDnsInfo(it, .main)) |dns| {
                primary = dns;
            } else |_| {}
            if (netif_api.getDnsInfo(it, .backup)) |dns| {
                secondary = dns;
            } else |_| {}
        }
        return .{ .primary = primary, .secondary = secondary };
    }

    pub fn setDns(_: NetIf, primary: Ipv4Address, secondary: ?Ipv4Address) void {
        var it: netif_api.Handle = null;
        it = netif_api.nextNetif(it);
        if (it != null) {
            netif_api.setDnsInfo(it, .main, primary) catch {};
            if (secondary) |s| {
                netif_api.setDnsInfo(it, .backup, s) catch {};
            }
        }
    }

    pub fn addRoute(_: NetIf, route: Route) void {
        var i: usize = 0;
        while (i < route_count) : (i += 1) {
            if (std.mem.eql(u8, &routes[i].dest, &route.dest) and
                std.mem.eql(u8, &routes[i].mask, &route.mask))
            {
                routes[i] = route;
                return;
            }
        }
        if (route_count < routes.len) {
            routes[route_count] = route;
            route_count += 1;
        } else {
            routes[routes.len - 1] = route;
        }
    }

    pub fn delRoute(_: NetIf, dest: Ipv4Address, mask: Ipv4Address) void {
        var i: usize = 0;
        while (i < route_count) : (i += 1) {
            if (std.mem.eql(u8, &routes[i].dest, &dest) and
                std.mem.eql(u8, &routes[i].mask, &mask))
            {
                var j = i;
                while (j + 1 < route_count) : (j += 1) {
                    routes[j] = routes[j + 1];
                }
                route_count -= 1;
                return;
            }
        }
    }

    fn findHandle(name: IfName) ?netif_api.Handle {
        const target = ifNameSlice(&name);
        if (target.len == 0) return null;

        var it: netif_api.Handle = null;
        it = netif_api.nextNetif(it);
        while (it != null) : (it = netif_api.nextNetif(it)) {
            if (netif_api.getImplName(it)) |impl_name| {
                var len: usize = 0;
                while (len < impl_name.len and impl_name[len] != 0) : (len += 1) {}
                if (std.mem.eql(u8, impl_name[0..len], target)) return it;
            } else |_| {}
        }
        return null;
    }

    fn ifNameLen(name: IfName) u8 {
        var i: usize = 0;
        while (i < name.len and name[i] != 0) : (i += 1) {}
        return @intCast(i);
    }

    fn ifNameSlice(name: *const IfName) []const u8 {
        var i: usize = 0;
        while (i < name.len and name[i] != 0) : (i += 1) {}
        return name[0..i];
    }

    fn toIfName(buf: *const [16]u8) IfName {
        var ifn: IfName = std.mem.zeroes(IfName);
        var len: usize = 0;
        while (len < buf.len and buf[len] != 0) : (len += 1) {}
        const n = @min(len, ifn.len);
        @memcpy(ifn[0..n], buf[0..n]);
        return ifn;
    }
};
