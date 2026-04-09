const std = @import("std");
const Stack = @This();
const testing_api = @import("testing");

ptr: *anyopaque,
vtable: *const VTable,

/// Semantic kind of payload carried by an interface.
pub const IfaceKind = enum {
    ethernet,
    ppp,
    ip,
};

/// Backend/source of an interface implementation.
pub const IfaceBackend = enum {
    unknown,
    physical,
    tap,
    tun,
    utun,
    serial,
    custom,
};

pub const Iface = struct {
    id: u32,
};

/// Pure IP prefix used for interface address configuration.
pub const Prefix = union(enum) {
    ipv4: Ip4,
    ipv6: Ip6,

    pub const Ip4 = struct {
        addr: [4]u8,
        len: u8,
    };

    pub const Ip6 = struct {
        addr: [16]u8,
        len: u8,
        scope_id: u32 = 0,
    };

    pub fn initIp4(addr: [4]u8, len: u8) Prefix {
        return .{ .ipv4 = .{ .addr = addr, .len = len } };
    }

    pub fn initIp6(addr: [16]u8, len: u8, scope_id: u32) Prefix {
        return .{ .ipv6 = .{ .addr = addr, .len = len, .scope_id = scope_id } };
    }
};

pub const IfaceInfo = struct {
    iface: Iface,
    kind: IfaceKind,
    backend: IfaceBackend = .unknown,
    mtu: usize,
    name: [32]u8 = .{0} ** 32,
    name_len: u8 = 0,

    pub fn getName(self: *const IfaceInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const ListIfacesError = error{Unexpected};
pub const GetIfaceInfoError = error{
    InvalidIface,
    Unexpected,
};
pub const DefaultIfaceError = error{Unexpected};
pub const SetDefaultIfaceError = error{
    InvalidIface,
    Unexpected,
};
pub const AddrError = error{
    InvalidIface,
    InvalidPrefixLen,
    AccessDenied,
    Unexpected,
};
pub const PollError = error{
    TimedOut,
    Unexpected,
};

pub const VTable = struct {
    listIfaces: *const fn (ptr: *anyopaque, out: []IfaceInfo) ListIfacesError!usize,
    getIfaceInfo: *const fn (ptr: *anyopaque, iface: Iface) GetIfaceInfoError!IfaceInfo,
    defaultIface: *const fn (ptr: *anyopaque) DefaultIfaceError!?Iface,
    setDefaultIface: *const fn (ptr: *anyopaque, iface: Iface) SetDefaultIfaceError!void,
    addAddr: *const fn (ptr: *anyopaque, iface: Iface, prefix: Prefix) AddrError!void,
    delAddr: *const fn (ptr: *anyopaque, iface: Iface, prefix: Prefix) AddrError!void,
    poll: *const fn (ptr: *anyopaque, timeout_ms: ?u32) PollError!void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn listIfaces(self: Stack, out: []IfaceInfo) ListIfacesError!usize {
    return self.vtable.listIfaces(self.ptr, out);
}

pub fn getIfaceInfo(self: Stack, iface: Iface) GetIfaceInfoError!IfaceInfo {
    return self.vtable.getIfaceInfo(self.ptr, iface);
}

pub fn defaultIface(self: Stack) DefaultIfaceError!?Iface {
    return self.vtable.defaultIface(self.ptr);
}

pub fn setDefaultIface(self: Stack, iface: Iface) SetDefaultIfaceError!void {
    return self.vtable.setDefaultIface(self.ptr, iface);
}

pub fn addAddr(self: Stack, iface: Iface, prefix: Prefix) AddrError!void {
    return self.vtable.addAddr(self.ptr, iface, prefix);
}

pub fn delAddr(self: Stack, iface: Iface, prefix: Prefix) AddrError!void {
    return self.vtable.delAddr(self.ptr, iface, prefix);
}

pub fn poll(self: Stack, timeout_ms: ?u32) PollError!void {
    return self.vtable.poll(self.ptr, timeout_ms);
}

pub fn deinit(self: Stack) void {
    self.vtable.deinit(self.ptr);
}

pub fn init(pointer: *anyopaque, vtable: *const VTable) Stack {
    return .{
        .ptr = pointer,
        .vtable = vtable,
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 0, struct {
        fn run(_: *testing_api.T, _: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const S = Stack;

            const Impl = struct {
                default_iface: ?S.Iface = null,
                add_prefix_called: bool = false,
                del_prefix_called: bool = false,
                deinit_called: bool = false,

                fn makeInfo(id: u32, name: []const u8, kind: S.IfaceKind, backend: S.IfaceBackend, mtu: usize) S.IfaceInfo {
                    var info: S.IfaceInfo = .{
                        .iface = .{ .id = id },
                        .kind = kind,
                        .backend = backend,
                        .mtu = mtu,
                    };
                    std.mem.copyForwards(u8, info.name[0..name.len], name);
                    info.name_len = @intCast(name.len);
                    return info;
                }

                pub fn listIfaces(_: *@This(), out: []S.IfaceInfo) S.ListIfacesError!usize {
                    if (out.len == 0) return 0;
                    out[0] = makeInfo(7, "utun0", .ip, .utun, 1380);
                    return 1;
                }

                pub fn getIfaceInfo(_: *@This(), iface: S.Iface) S.GetIfaceInfoError!S.IfaceInfo {
                    if (iface.id != 7) return error.InvalidIface;
                    return makeInfo(7, "utun0", .ip, .utun, 1380);
                }

                pub fn defaultIface(self: *@This()) S.DefaultIfaceError!?S.Iface {
                    return self.default_iface;
                }

                pub fn setDefaultIface(self: *@This(), iface: S.Iface) S.SetDefaultIfaceError!void {
                    if (iface.id != 7) return error.InvalidIface;
                    self.default_iface = iface;
                }

                pub fn addAddr(self: *@This(), iface: S.Iface, prefix: S.Prefix) S.AddrError!void {
                    if (iface.id != 7) return error.InvalidIface;
                    switch (prefix) {
                        .ipv4 => |p| if (p.len > 32) return error.InvalidPrefixLen,
                        .ipv6 => |p| if (p.len > 128) return error.InvalidPrefixLen,
                    }
                    self.add_prefix_called = true;
                }

                pub fn delAddr(self: *@This(), iface: S.Iface, prefix: S.Prefix) S.AddrError!void {
                    if (iface.id != 7) return error.InvalidIface;
                    switch (prefix) {
                        .ipv4 => |p| if (p.len > 32) return error.InvalidPrefixLen,
                        .ipv6 => |p| if (p.len > 128) return error.InvalidPrefixLen,
                    }
                    self.del_prefix_called = true;
                }

                pub fn poll(_: *@This(), timeout_ms: ?u32) S.PollError!void {
                    _ = timeout_ms;
                }

                pub fn deinit(self: *@This()) void {
                    self.deinit_called = true;
                }
            };

            const TestVTable = S.VTable{
                .listIfaces = struct {
                    fn f(ptr: *anyopaque, out: []S.IfaceInfo) S.ListIfacesError!usize {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.listIfaces(out);
                    }
                }.f,
                .getIfaceInfo = struct {
                    fn f(ptr: *anyopaque, iface: S.Iface) S.GetIfaceInfoError!S.IfaceInfo {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.getIfaceInfo(iface);
                    }
                }.f,
                .defaultIface = struct {
                    fn f(ptr: *anyopaque) S.DefaultIfaceError!?S.Iface {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.defaultIface();
                    }
                }.f,
                .setDefaultIface = struct {
                    fn f(ptr: *anyopaque, iface: S.Iface) S.SetDefaultIfaceError!void {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.setDefaultIface(iface);
                    }
                }.f,
                .addAddr = struct {
                    fn f(ptr: *anyopaque, iface: S.Iface, prefix: S.Prefix) S.AddrError!void {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.addAddr(iface, prefix);
                    }
                }.f,
                .delAddr = struct {
                    fn f(ptr: *anyopaque, iface: S.Iface, prefix: S.Prefix) S.AddrError!void {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.delAddr(iface, prefix);
                    }
                }.f,
                .poll = struct {
                    fn f(ptr: *anyopaque, timeout_ms: ?u32) S.PollError!void {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.poll(timeout_ms);
                    }
                }.f,
                .deinit = struct {
                    fn f(ptr: *anyopaque) void {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        self.deinit();
                    }
                }.f,
            };

            var impl = Impl{};
            const stack = S.init(@ptrCast(&impl), &TestVTable);

            var infos: [1]S.IfaceInfo = undefined;
            const n = try stack.listIfaces(&infos);
            try testing.expectEqual(@as(usize, 1), n);
            try testing.expectEqualStrings("utun0", infos[0].getName());
            try testing.expectEqual(S.IfaceKind.ip, infos[0].kind);
            try testing.expectEqual(S.IfaceBackend.utun, infos[0].backend);

            const iface = try stack.defaultIface();
            try testing.expectEqual(@as(?S.Iface, null), iface);

            try stack.setDefaultIface(.{ .id = 7 });
            const default_iface = (try stack.defaultIface()).?;
            try testing.expectEqual(@as(u32, 7), default_iface.id);

            const info = try stack.getIfaceInfo(.{ .id = 7 });
            try testing.expectEqual(@as(usize, 1380), info.mtu);

            try stack.addAddr(.{ .id = 7 }, S.Prefix.initIp4(.{ 10, 0, 0, 1 }, 24));
            try testing.expect(impl.add_prefix_called);

            try stack.delAddr(.{ .id = 7 }, S.Prefix.initIp4(.{ 10, 0, 0, 1 }, 24));
            try testing.expect(impl.del_prefix_called);

            try stack.poll(0);
            stack.deinit();
            try testing.expect(impl.deinit_called);
        }
    }.run);
}
