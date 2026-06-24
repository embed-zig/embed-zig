const embed_adapter = @import("esp_embed");
const glib = @import("glib");
const esp_grt = @import("esp_grt");

const binding = esp_grt.net.binding;
const net = embed_adapter.net;

pub const Manager = struct {
    pub fn init() Manager {
        return .{};
    }

    pub fn interfaceManager(self: *Manager) net.Manager {
        return net.Manager.init(self);
    }

    pub fn listInterfaces(_: *Manager, out: []net.iface.Info) net.Error![]net.iface.Info {
        if (out.len == 0) return error.BufferTooSmall;

        var raw_buf: [16]binding.netif_info = undefined;
        const cap = @min(raw_buf.len, out.len);
        const raw_count = binding.espz_netif_list(&raw_buf, cap);
        if (raw_count > cap) return error.BufferTooSmall;

        var count: usize = 0;
        while (count < raw_count) : (count += 1) {
            out[count] = try infoFromBinding(raw_buf[count]);
        }
        return out[0..count];
    }

    pub fn getDefaultRoute(_: *Manager, family: net.AddressFamily) net.Error!?net.route.Default {
        if (family != .ipv4) return null;

        var id: usize = 0;
        try checkEsp(binding.espz_netif_get_default(&id));
        if (id == 0) return null;

        var raw_buf: [16]binding.netif_info = undefined;
        const raw_count = binding.espz_netif_list(&raw_buf, raw_buf.len);
        const count = @min(raw_count, raw_buf.len);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const raw = raw_buf[index];
            if (raw.id != id) continue;
            return .{
                .family = family,
                .interface_id = id,
                .gateway = if (raw.has_ipv4 != 0 and !isZero4(raw.gateway))
                    glib.net.netip.Addr.from4(raw.gateway)
                else
                    null,
                .metric = if (raw.route_prio >= 0) @intCast(raw.route_prio) else 0,
            };
        }

        return .{
            .family = family,
            .interface_id = id,
        };
    }

    pub fn setDefaultRoute(_: *Manager, default: net.route.Default) net.Error!void {
        if (default.family != .ipv4) return error.InvalidRoute;
        try checkEsp(binding.espz_netif_set_default(default.interface_id));
    }
};

fn infoFromBinding(raw: binding.netif_info) net.Error!net.iface.Info {
    const name = raw.name[0..@min(raw.name_len, raw.name.len)];
    var info = try net.iface.Info.init(raw.id, name);
    info.flags.up = raw.up != 0;
    info.flags.running = raw.up != 0;
    info.flags.default = raw.is_default != 0;
    if (raw.has_ipv4 != 0) {
        try info.appendAddress(.{
            .family = .ipv4,
            .address = glib.net.netip.Addr.from4(raw.ipv4),
            .prefix_len = prefixLen4(raw.netmask),
        });
    }
    return info;
}

fn checkEsp(rc: c_int) net.Error!void {
    if (rc == 0) return;
    if (rc == -2) return error.InvalidInterface;
    if (rc == -1) return error.Unsupported;
    return error.Unexpected;
}

fn isZero4(bytes: [4]u8) bool {
    return bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0;
}

fn prefixLen4(bytes: [4]u8) u8 {
    var prefix: u8 = 0;
    for (bytes) |byte| {
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u8 = @as(u8, 0x80) >> @intCast(bit);
            if ((byte & mask) == 0) return prefix;
            prefix += 1;
        }
    }
    return prefix;
}
