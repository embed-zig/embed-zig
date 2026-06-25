const glib = @import("glib");
const std = @import("std");

pub const InterfaceId = glib.net.InterfaceId;
pub const AddressFamily = glib.net.AddressFamily;
pub const AddressInfo = glib.net.AddressInfo;
pub const InterfaceInfo = glib.net.InterfaceInfo;
pub const InterfaceFlags = glib.net.InterfaceFlags;
pub const InterfaceEvent = glib.net.InterfaceEvent;
pub const DefaultRoute = glib.net.DefaultRoute;
pub const netip = glib.net.netip;

pub const interfaces = struct {
    pub fn list(out: []InterfaceInfo) glib.net.types.Error![]InterfaceInfo {
        if (out.len == 0) return error.BufferTooSmall;

        var addrs: ?*IfAddrs = null;
        if (getifaddrs(&addrs) != 0) return error.Unexpected;
        defer freeifaddrs(addrs);

        var count: usize = 0;
        var current = addrs;
        while (current) |entry| : (current = entry.ifa_next) {
            const name = std.mem.span(entry.ifa_name);
            if (name.len == 0) continue;

            const id = interfaceId(entry.ifa_name, count);
            const index = findOrAppendInterface(out, &count, id, name) catch |err| return err;
            applyFlags(&out[index], entry.ifa_flags);
            if (addressFromSockaddr(entry.ifa_addr, entry.ifa_netmask)) |address| {
                appendAddressBestEffort(&out[index], address);
            }
        }
        return out[0..count];
    }

    pub fn addEventHook(_: glib.net.interfaces.EventHook) glib.net.types.Error!void {
        return error.Unsupported;
    }

    pub fn removeEventHook(_: glib.net.interfaces.EventHook) glib.net.types.Error!void {
        return error.Unsupported;
    }
};

pub const routes = struct {
    pub fn getDefault(_: AddressFamily) glib.net.types.Error!?DefaultRoute {
        return null;
    }

    pub fn setDefault(_: DefaultRoute) glib.net.types.Error!void {
        return error.Unsupported;
    }
};

const IfAddrs = extern struct {
    ifa_next: ?*IfAddrs,
    ifa_name: [*:0]const u8,
    ifa_flags: c_uint,
    ifa_addr: ?*std.c.sockaddr,
    ifa_netmask: ?*std.c.sockaddr,
    ifa_dstaddr: ?*std.c.sockaddr,
    ifa_data: ?*anyopaque,
};

extern "c" fn getifaddrs(ifap: *?*IfAddrs) c_int;
extern "c" fn freeifaddrs(ifa: ?*IfAddrs) void;

const iff_up: c_uint = 0x1;
const iff_loopback: c_uint = 0x8;
const iff_running: c_uint = 0x40;

fn interfaceId(name: [*:0]const u8, fallback_index: usize) InterfaceId {
    const raw = std.c.if_nametoindex(name);
    return if (raw > 0) @intCast(raw) else fallback_index + 1;
}

fn findOrAppendInterface(
    out: []InterfaceInfo,
    count: *usize,
    id: InterfaceId,
    name: []const u8,
) glib.net.types.Error!usize {
    var index: usize = 0;
    while (index < count.*) : (index += 1) {
        if (out[index].id == id) return index;
        if (std.mem.eql(u8, out[index].name(), name)) return index;
    }
    if (count.* >= out.len) return error.BufferTooSmall;
    out[count.*] = InterfaceInfo.init(id, name);
    count.* += 1;
    return count.* - 1;
}

fn applyFlags(info: *InterfaceInfo, raw: c_uint) void {
    info.flags.up = info.flags.up or (raw & iff_up) != 0;
    info.flags.running = info.flags.running or (raw & iff_running) != 0;
    info.flags.loopback = info.flags.loopback or (raw & iff_loopback) != 0;
}

fn appendAddressBestEffort(info: *InterfaceInfo, address: AddressInfo) void {
    info.appendAddress(address) catch {};
}

fn addressFromSockaddr(
    addr_sock: ?*std.c.sockaddr,
    mask_sock: ?*std.c.sockaddr,
) ?AddressInfo {
    const addr = addr_sock orelse return null;
    if (addr.family == std.c.AF.INET) return ipv4Address(addr, mask_sock);
    if (addr.family == std.c.AF.INET6) return ipv6Address(addr, mask_sock);
    return null;
}

fn ipv4Address(addr: *const std.c.sockaddr, mask_sock: ?*std.c.sockaddr) AddressInfo {
    const in_addr: *const std.c.sockaddr.in = @ptrCast(@alignCast(addr));
    const bytes: [4]u8 = @bitCast(in_addr.addr);
    return .{
        .family = .ipv4,
        .address = netip.Addr.from4(bytes),
        .prefix_len = ipv4PrefixLen(mask_sock),
    };
}

fn ipv6Address(addr: *const std.c.sockaddr, mask_sock: ?*std.c.sockaddr) AddressInfo {
    const in_addr: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(addr));
    return .{
        .family = .ipv6,
        .address = netip.Addr.from16(in_addr.addr),
        .prefix_len = ipv6PrefixLen(mask_sock),
    };
}

fn ipv4PrefixLen(mask_sock: ?*std.c.sockaddr) u8 {
    const mask = mask_sock orelse return 0;
    if (mask.family != std.c.AF.INET) return 0;
    const in_addr: *const std.c.sockaddr.in = @ptrCast(@alignCast(mask));
    const bytes: [4]u8 = @bitCast(in_addr.addr);
    return prefixLen(&bytes, 32);
}

fn ipv6PrefixLen(mask_sock: ?*std.c.sockaddr) u8 {
    const mask = mask_sock orelse return 0;
    if (mask.family != std.c.AF.INET6) return 0;
    const in_addr: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(mask));
    return prefixLen(&in_addr.addr, 128);
}

fn prefixLen(bytes: []const u8, max_bits: u8) u8 {
    var prefix: u8 = 0;
    for (bytes) |byte| {
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            if ((byte & (@as(u8, 0x80) >> @intCast(bit))) == 0) return prefix;
            prefix += 1;
            if (prefix == max_bits) return prefix;
        }
    }
    return prefix;
}

pub fn TestRunner(comptime std_api: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn listInterfacesRejectsEmptyOutput() !void {
            try std_api.testing.expectError(error.BufferTooSmall, interfaces.list(&.{}));
        }

        fn listInterfacesIncludesLoopback() !void {
            var buf: [32]InterfaceInfo = undefined;
            const items = try interfaces.list(&buf);
            try std_api.testing.expect(items.len > 0);

            var found_loopback = false;
            for (items) |item| {
                if (item.flags.loopback) found_loopback = true;
            }
            try std_api.testing.expect(found_loopback);
        }

        fn defaultRouteIsNotMutatedOnDesktop() !void {
            try std_api.testing.expectEqual(@as(?DefaultRoute, null), try routes.getDefault(.ipv4));
            try std_api.testing.expectError(error.Unsupported, routes.setDefault(.{
                .family = .ipv4,
                .interface_id = 1,
            }));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std_api.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: std_api.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.listInterfacesRejectsEmptyOutput() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.listInterfacesIncludesLoopback() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultRouteIsNotMutatedOnDesktop() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std_api.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
