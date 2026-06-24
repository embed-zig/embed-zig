const glib = @import("glib");
const wifi_binding = @import("embed/wifi/binding.zig");

pub const InterfaceId = glib.net.InterfaceId;
pub const AddressFamily = glib.net.AddressFamily;
pub const AddressInfo = glib.net.AddressInfo;
pub const InterfaceInfo = glib.net.InterfaceInfo;
pub const DefaultRoute = glib.net.DefaultRoute;
pub const netip = glib.net.netip;

const sta_interface_id: InterfaceId = 1;
const sta_interface_name = "sta0";

pub const interfaces = struct {
    pub fn list(out: []InterfaceInfo) glib.net.types.Error![]InterfaceInfo {
        if (out.len == 0) return error.BufferTooSmall;

        var info = InterfaceInfo.init(sta_interface_id, sta_interface_name);
        const connected = wifi_binding.bk_embed_wifi_sta_state() == wifi_binding.state_connected;
        info.flags.up = connected;
        info.flags.running = false;
        info.flags.default = false;

        if (ipInfo()) |ip| {
            info.flags.up = true;
            info.flags.running = true;
            info.flags.default = true;
            try info.appendAddress(.{
                .family = .ipv4,
                .address = netip.Addr.from4(ip.address),
                .prefix_len = prefixLen4(ip.netmask),
            });
        }

        out[0] = info;
        return out[0..1];
    }

    pub fn addEventHook(_: glib.net.interfaces.EventHook) glib.net.types.Error!void {
        return error.Unsupported;
    }

    pub fn removeEventHook(_: glib.net.interfaces.EventHook) glib.net.types.Error!void {
        return error.Unsupported;
    }
};

pub const routes = struct {
    pub fn getDefault(family: AddressFamily) glib.net.types.Error!?DefaultRoute {
        if (family != .ipv4) return null;
        const ip = ipInfo() orelse return null;
        return .{
            .family = family,
            .interface_id = sta_interface_id,
            .gateway = if (isZero4(ip.gateway)) null else netip.Addr.from4(ip.gateway),
        };
    }

    pub fn setDefault(route: DefaultRoute) glib.net.types.Error!void {
        if (route.family != .ipv4) return error.InvalidRoute;
        if (route.interface_id != sta_interface_id) return error.InvalidInterface;
    }
};

const IpInfo = struct {
    address: [4]u8,
    gateway: [4]u8,
    netmask: [4]u8,
};

fn ipInfo() ?IpInfo {
    var address: [4]u8 = undefined;
    var gateway: [4]u8 = undefined;
    var netmask: [4]u8 = undefined;
    var dns1: [4]u8 = undefined;
    if (wifi_binding.bk_embed_wifi_sta_get_ip_info(&address, &gateway, &netmask, &dns1) != wifi_binding.ok) {
        return null;
    }
    if (isZero4(address)) return null;
    return .{
        .address = address,
        .gateway = gateway,
        .netmask = netmask,
    };
}

fn prefixLen4(netmask: [4]u8) u8 {
    var prefix: u8 = 0;
    for (netmask) |byte| {
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u8 = @as(u8, 0x80) >> @intCast(bit);
            if ((byte & mask) == 0) return prefix;
            prefix += 1;
        }
    }
    return prefix;
}

fn isZero4(bytes: [4]u8) bool {
    return bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0;
}
