const Context = @import("event/Context.zig");
const event = @import("event.zig");
const net = glib.net;
const glib = @import("glib");

const Addr = net.netip.Addr;
const EventReceiver = event.EventReceiver;
const NetStack = @This();

pub const max_dns_server_count: usize = 4;
pub const max_netif_name_len: usize = 32;

ptr: *anyopaque,
vtable: *const VTable,

pub const AddrSource = enum {
    unknown,
    manual,
    dhcp,
    ppp,
    slaac,
    link_local,
};

pub const NetifDownReason = enum {
    unknown,
    admin_down,
    link_down,
    disconnected,
    fault,
};

pub const PppPhase = enum {
    dead,
    establish,
    authenticate,
    network,
    running,
    terminate,
};

pub const PppAuthProtocol = enum {
    none,
    pap,
    chap,
};

pub const PppDownReason = enum {
    unknown,
    local_close,
    peer_terminated,
    auth_failed,
    timeout,
    carrier_lost,
    protocol_error,
};

pub const NetifType = enum {
    unknown,
    ethernet,
    wifi,
    ppp,
    loopback,
    bridge,
    vlan,
    tunnel,
};

pub const NetifCreatedEvent = struct {
    pub const kind = .netstack_netif_created;

    source_id: u32,
    netif_id: u32,
    netif_type: NetifType,
    name_end: u8,
    name_buf: [max_netif_name_len]u8,
    ctx: Context.Type = null,

    pub fn name(self: *const @This()) []const u8 {
        return self.name_buf[0..self.name_end];
    }
};

pub const NetifDestroyedEvent = struct {
    pub const kind = .netstack_netif_destroyed;

    source_id: u32,
    netif_id: u32,
    netif_type: NetifType,
    name_end: u8,
    name_buf: [max_netif_name_len]u8,
    ctx: Context.Type = null,

    pub fn name(self: *const @This()) []const u8 {
        return self.name_buf[0..self.name_end];
    }
};

pub const NetifUpEvent = struct {
    pub const kind = .netstack_netif_up;

    source_id: u32,
    netif_id: u32,
    ctx: Context.Type = null,
};

pub const NetifDownEvent = struct {
    pub const kind = .netstack_netif_down;

    source_id: u32,
    netif_id: u32,
    reason: NetifDownReason,
    ctx: Context.Type = null,
};

pub const AddrAddedEvent = struct {
    pub const kind = .netstack_addr_added;

    source_id: u32,
    netif_id: u32,
    addr: Addr,
    prefix_len: u8,
    source: AddrSource,
    ctx: Context.Type = null,
};

pub const AddrRemovedEvent = struct {
    pub const kind = .netstack_addr_removed;

    source_id: u32,
    netif_id: u32,
    addr: Addr,
    prefix_len: u8,
    source: AddrSource,
    ctx: Context.Type = null,
};

pub const DhcpLeaseAcquiredEvent = struct {
    pub const kind = .netstack_dhcp_lease_acquired;

    source_id: u32,
    netif_id: u32,
    addr: Addr,
    gateway: Addr,
    netmask: Addr,
    dns_count: u8,
    dns_buf: [max_dns_server_count]Addr,
    lease_time_s: u32,
    ctx: Context.Type = null,

    pub fn dnsServers(self: *const @This()) []const Addr {
        return self.dns_buf[0..self.dns_count];
    }
};

pub const DhcpLeaseLostEvent = struct {
    pub const kind = .netstack_dhcp_lease_lost;

    source_id: u32,
    netif_id: u32,
    ctx: Context.Type = null,
};

pub const DefaultRouteChangedEvent = struct {
    pub const kind = .netstack_default_route_changed;

    source_id: u32,
    netif_id: u32,
    gateway: Addr,
    ctx: Context.Type = null,
};

pub const RouterDiscoveredEvent = struct {
    pub const kind = .netstack_router_discovered;

    source_id: u32,
    netif_id: u32,
    router: Addr,
    ctx: Context.Type = null,
};

pub const RouterLostEvent = struct {
    pub const kind = .netstack_router_lost;

    source_id: u32,
    netif_id: u32,
    router: Addr,
    ctx: Context.Type = null,
};

pub const DnsServersChangedEvent = struct {
    pub const kind = .netstack_dns_servers_changed;

    source_id: u32,
    netif_id: u32,
    dns_count: u8,
    dns_buf: [max_dns_server_count]Addr,
    ctx: Context.Type = null,

    pub fn dnsServers(self: *const @This()) []const Addr {
        return self.dns_buf[0..self.dns_count];
    }
};

pub const PppPhaseChangedEvent = struct {
    pub const kind = .netstack_ppp_phase_changed;

    source_id: u32,
    netif_id: u32,
    phase: PppPhase,
    ctx: Context.Type = null,
};

pub const PppAuthSucceededEvent = struct {
    pub const kind = .netstack_ppp_auth_succeeded;

    source_id: u32,
    netif_id: u32,
    protocol: PppAuthProtocol,
    ctx: Context.Type = null,
};

pub const PppAuthFailedEvent = struct {
    pub const kind = .netstack_ppp_auth_failed;

    source_id: u32,
    netif_id: u32,
    protocol: PppAuthProtocol,
    ctx: Context.Type = null,
};

pub const PppUpEvent = struct {
    pub const kind = .netstack_ppp_up;

    source_id: u32,
    netif_id: u32,
    local_addr: Addr,
    peer_addr: Addr,
    ctx: Context.Type = null,
};

pub const PppDownEvent = struct {
    pub const kind = .netstack_ppp_down;

    source_id: u32,
    netif_id: u32,
    reason: PppDownReason,
    ctx: Context.Type = null,
};

pub const NetifCreated = struct {
    source_id: u32,
    netif_id: u32,
    netif_type: NetifType = .unknown,
    name: ?[]const u8 = null,
    ctx: Context.Type = null,
};

pub const NetifDestroyed = struct {
    source_id: u32,
    netif_id: u32,
    netif_type: NetifType = .unknown,
    name: ?[]const u8 = null,
    ctx: Context.Type = null,
};

pub const NetifUp = struct {
    source_id: u32,
    netif_id: u32,
    ctx: Context.Type = null,
};

pub const NetifDown = struct {
    source_id: u32,
    netif_id: u32,
    reason: NetifDownReason,
    ctx: Context.Type = null,
};

pub const AddrAdded = struct {
    source_id: u32,
    netif_id: u32,
    addr: Addr,
    prefix_len: u8,
    source: AddrSource,
    ctx: Context.Type = null,
};

pub const AddrRemoved = struct {
    source_id: u32,
    netif_id: u32,
    addr: Addr,
    prefix_len: u8,
    source: AddrSource,
    ctx: Context.Type = null,
};

pub const DhcpLeaseAcquired = struct {
    source_id: u32,
    netif_id: u32,
    addr: Addr,
    gateway: Addr,
    netmask: Addr,
    dns_servers: []const Addr = &.{},
    lease_time_s: u32 = 0,
    ctx: Context.Type = null,
};

pub const DhcpLeaseLost = struct {
    source_id: u32,
    netif_id: u32,
    ctx: Context.Type = null,
};

pub const DefaultRouteChanged = struct {
    source_id: u32,
    netif_id: u32,
    gateway: Addr,
    ctx: Context.Type = null,
};

pub const RouterDiscovered = struct {
    source_id: u32,
    netif_id: u32,
    router: Addr,
    ctx: Context.Type = null,
};

pub const RouterLost = struct {
    source_id: u32,
    netif_id: u32,
    router: Addr,
    ctx: Context.Type = null,
};

pub const DnsServersChanged = struct {
    source_id: u32,
    netif_id: u32,
    dns_servers: []const Addr,
    ctx: Context.Type = null,
};

pub const PppPhaseChanged = struct {
    source_id: u32,
    netif_id: u32,
    phase: PppPhase,
    ctx: Context.Type = null,
};

pub const PppAuthSucceeded = struct {
    source_id: u32,
    netif_id: u32,
    protocol: PppAuthProtocol,
    ctx: Context.Type = null,
};

pub const PppAuthFailed = struct {
    source_id: u32,
    netif_id: u32,
    protocol: PppAuthProtocol,
    ctx: Context.Type = null,
};

pub const PppUp = struct {
    source_id: u32,
    netif_id: u32,
    local_addr: Addr,
    peer_addr: Addr,
    ctx: Context.Type = null,
};

pub const PppDown = struct {
    source_id: u32,
    netif_id: u32,
    reason: PppDownReason,
    ctx: Context.Type = null,
};

pub const Update = union(enum) {
    netif_created: NetifCreated,
    netif_destroyed: NetifDestroyed,
    netif_up: NetifUp,
    netif_down: NetifDown,
    addr_added: AddrAdded,
    addr_removed: AddrRemoved,
    dhcp_lease_acquired: DhcpLeaseAcquired,
    dhcp_lease_lost: DhcpLeaseLost,
    default_route_changed: DefaultRouteChanged,
    router_discovered: RouterDiscovered,
    router_lost: RouterLost,
    dns_servers_changed: DnsServersChanged,
    ppp_phase_changed: PppPhaseChanged,
    ppp_auth_succeeded: PppAuthSucceeded,
    ppp_auth_failed: PppAuthFailed,
    ppp_up: PppUp,
    ppp_down: PppDown,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, update: Update) void;

pub const VTable = struct {
    setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void,
    clearEventCallback: *const fn (ptr: *anyopaque) void,
};

pub fn makeEvent(update: Update) !event.Event {
    return switch (update) {
        .netif_created => |value| .{
            .netstack_netif_created = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .netif_type = value.netif_type,
                .name_end = try copyNetifNameLen(value.name),
                .name_buf = try copyNetifNameBuf(value.name),
                .ctx = value.ctx,
            },
        },
        .netif_destroyed => |value| .{
            .netstack_netif_destroyed = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .netif_type = value.netif_type,
                .name_end = try copyNetifNameLen(value.name),
                .name_buf = try copyNetifNameBuf(value.name),
                .ctx = value.ctx,
            },
        },
        .netif_up => |value| .{
            .netstack_netif_up = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .ctx = value.ctx,
            },
        },
        .netif_down => |value| .{
            .netstack_netif_down = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .reason = value.reason,
                .ctx = value.ctx,
            },
        },
        .addr_added => |value| .{
            .netstack_addr_added = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .addr = value.addr,
                .prefix_len = value.prefix_len,
                .source = value.source,
                .ctx = value.ctx,
            },
        },
        .addr_removed => |value| .{
            .netstack_addr_removed = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .addr = value.addr,
                .prefix_len = value.prefix_len,
                .source = value.source,
                .ctx = value.ctx,
            },
        },
        .dhcp_lease_acquired => |value| .{
            .netstack_dhcp_lease_acquired = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .addr = value.addr,
                .gateway = value.gateway,
                .netmask = value.netmask,
                .dns_count = try copyDnsCount(value.dns_servers),
                .dns_buf = try copyDnsBuf(value.dns_servers),
                .lease_time_s = value.lease_time_s,
                .ctx = value.ctx,
            },
        },
        .dhcp_lease_lost => |value| .{
            .netstack_dhcp_lease_lost = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .ctx = value.ctx,
            },
        },
        .default_route_changed => |value| .{
            .netstack_default_route_changed = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .gateway = value.gateway,
                .ctx = value.ctx,
            },
        },
        .router_discovered => |value| .{
            .netstack_router_discovered = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .router = value.router,
                .ctx = value.ctx,
            },
        },
        .router_lost => |value| .{
            .netstack_router_lost = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .router = value.router,
                .ctx = value.ctx,
            },
        },
        .dns_servers_changed => |value| .{
            .netstack_dns_servers_changed = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .dns_count = try copyDnsCount(value.dns_servers),
                .dns_buf = try copyDnsBuf(value.dns_servers),
                .ctx = value.ctx,
            },
        },
        .ppp_phase_changed => |value| .{
            .netstack_ppp_phase_changed = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .phase = value.phase,
                .ctx = value.ctx,
            },
        },
        .ppp_auth_succeeded => |value| .{
            .netstack_ppp_auth_succeeded = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .protocol = value.protocol,
                .ctx = value.ctx,
            },
        },
        .ppp_auth_failed => |value| .{
            .netstack_ppp_auth_failed = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .protocol = value.protocol,
                .ctx = value.ctx,
            },
        },
        .ppp_up => |value| .{
            .netstack_ppp_up = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .local_addr = value.local_addr,
                .peer_addr = value.peer_addr,
                .ctx = value.ctx,
            },
        },
        .ppp_down => |value| .{
            .netstack_ppp_down = .{
                .source_id = value.source_id,
                .netif_id = value.netif_id,
                .reason = value.reason,
                .ctx = value.ctx,
            },
        },
    };
}

fn copyDnsCount(dns_servers: []const Addr) !u8 {
    if (dns_servers.len > max_dns_server_count) return error.InvalidDnsServerCount;
    return @intCast(dns_servers.len);
}

fn copyNetifNameLen(name: ?[]const u8) !u8 {
    const value = name orelse return 0;
    if (value.len > max_netif_name_len) return error.InvalidNetifNameLength;
    return @intCast(value.len);
}

fn copyNetifNameBuf(name: ?[]const u8) ![max_netif_name_len]u8 {
    const value = name orelse return [_]u8{0} ** max_netif_name_len;
    if (value.len > max_netif_name_len) return error.InvalidNetifNameLength;

    var buf = [_]u8{0} ** max_netif_name_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

fn copyDnsBuf(dns_servers: []const Addr) ![max_dns_server_count]Addr {
    if (dns_servers.len > max_dns_server_count) return error.InvalidDnsServerCount;

    var buf = [_]Addr{.{}} ** max_dns_server_count;
    @memcpy(buf[0..dns_servers.len], dns_servers);
    return buf;
}

pub fn setEventReceiver(self: NetStack, receiver: *const EventReceiver) void {
    self.vtable.setEventCallback(self.ptr, @ptrCast(receiver), eventReceiverEmitUpdate);
}

pub fn clearEventReceiver(self: NetStack) void {
    self.vtable.clearEventCallback(self.ptr);
}

pub fn init(comptime T: type, impl: *T) NetStack {
    comptime {
        _ = @as(*const fn (*T, *const anyopaque, CallbackFn) void, &T.setEventCallback);
        _ = @as(*const fn (*T) void, &T.clearEventCallback);
    }

    const gen = struct {
        fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }

        fn clearEventCallbackFn(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }

        const vtable = VTable{
            .setEventCallback = setEventCallbackFn,
            .clearEventCallback = clearEventCallbackFn,
        };
    };

    return .{
        .ptr = @ptrCast(impl),
        .vtable = &gen.vtable,
    };
}

fn eventReceiverEmitUpdate(ctx: *const anyopaque, update: Update) void {
    const receiver: *const EventReceiver = @ptrCast(@alignCast(ctx));
    const value = makeEvent(update) catch @panic("zux.NetStack received invalid adapter event");
    receiver.emit(value);
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn makeEventCopiesDhcpAndDnsFields(testing: anytype) !void {
            const dns = [_]Addr{
                Addr.from4(.{ 1, 1, 1, 1 }),
                Addr.from4(.{ 8, 8, 8, 8 }),
            };

            const value = try makeEvent(.{
                .dhcp_lease_acquired = .{
                    .source_id = 51,
                    .netif_id = 7,
                    .addr = Addr.from4(.{ 192, 168, 10, 23 }),
                    .gateway = Addr.from4(.{ 192, 168, 10, 1 }),
                    .netmask = Addr.from4(.{ 255, 255, 255, 0 }),
                    .dns_servers = dns[0..],
                    .lease_time_s = 7200,
                },
            });

            switch (value) {
                .netstack_dhcp_lease_acquired => |lease| {
                    try testing.expectEqual(@as(u32, 51), lease.source_id);
                    try testing.expectEqual(@as(u32, 7), lease.netif_id);
                    try testing.expectEqual(@as(u32, 7200), lease.lease_time_s);
                    try testing.expectEqual(@as([4]u8, .{ 192, 168, 10, 23 }), lease.addr.as4().?);
                    try testing.expectEqual(@as([4]u8, .{ 192, 168, 10, 1 }), lease.gateway.as4().?);
                    try testing.expectEqual(@as(usize, 2), lease.dnsServers().len);
                    try testing.expectEqual(@as([4]u8, .{ 1, 1, 1, 1 }), lease.dnsServers()[0].as4().?);
                    try testing.expectEqual(@as([4]u8, .{ 8, 8, 8, 8 }), lease.dnsServers()[1].as4().?);
                },
                else => try testing.expect(false),
            }
        }

        fn makeEventCopiesNetifMetadata(testing: anytype) !void {
            const value = try makeEvent(.{
                .netif_created = .{
                    .source_id = 60,
                    .netif_id = 2,
                    .netif_type = .wifi,
                    .name = "wlan0",
                },
            });

            switch (value) {
                .netstack_netif_created => |netif| {
                    try testing.expectEqual(@as(u32, 60), netif.source_id);
                    try testing.expectEqual(@as(u32, 2), netif.netif_id);
                    try testing.expectEqual(@as(NetifType, .wifi), netif.netif_type);
                    try testing.expectEqualStrings("wlan0", netif.name());
                },
                else => try testing.expect(false),
            }
        }

        fn makeEventMapsPppFields(testing: anytype) !void {
            const value = try makeEvent(.{
                .ppp_up = .{
                    .source_id = 61,
                    .netif_id = 9,
                    .local_addr = Addr.from4(.{ 10, 64, 0, 2 }),
                    .peer_addr = Addr.from4(.{ 10, 64, 0, 1 }),
                },
            });

            switch (value) {
                .netstack_ppp_up => |ppp| {
                    try testing.expectEqual(@as(u32, 61), ppp.source_id);
                    try testing.expectEqual(@as(u32, 9), ppp.netif_id);
                    try testing.expectEqual(@as([4]u8, .{ 10, 64, 0, 2 }), ppp.local_addr.as4().?);
                    try testing.expectEqual(@as([4]u8, .{ 10, 64, 0, 1 }), ppp.peer_addr.as4().?);
                },
                else => try testing.expect(false),
            }
        }

        fn registerAndEmitUpdatesThroughCallback(testing: anytype) !void {
            const Sink = struct {
                created_count: usize = 0,
                destroyed_count: usize = 0,
                up_count: usize = 0,
                dns_count: usize = 0,
                ppp_down_count: usize = 0,
                last_netif_type: ?NetifType = null,
                last_netif_name_len: usize = 0,
                last_ppp_phase: ?PppPhase = null,
                last_netif_id: u32 = 0,
                last_dns_count: usize = 0,
                last_ppp_down_reason: ?PppDownReason = null,

                fn emitFn(ctx: *const anyopaque, update: Update) void {
                    const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
                    switch (update) {
                        .netif_created => |value| {
                            self.created_count += 1;
                            self.last_netif_id = value.netif_id;
                            self.last_netif_type = value.netif_type;
                            self.last_netif_name_len = (value.name orelse "").len;
                        },
                        .netif_destroyed => |value| {
                            self.destroyed_count += 1;
                            self.last_netif_id = value.netif_id;
                            self.last_netif_type = value.netif_type;
                            self.last_netif_name_len = (value.name orelse "").len;
                        },
                        .netif_up => |value| {
                            self.up_count += 1;
                            self.last_netif_id = value.netif_id;
                        },
                        .dns_servers_changed => |value| {
                            self.dns_count += 1;
                            self.last_netif_id = value.netif_id;
                            self.last_dns_count = value.dns_servers.len;
                        },
                        .ppp_phase_changed => |value| {
                            self.last_netif_id = value.netif_id;
                            self.last_ppp_phase = value.phase;
                        },
                        .ppp_down => |value| {
                            self.ppp_down_count += 1;
                            self.last_netif_id = value.netif_id;
                            self.last_ppp_down_reason = value.reason;
                        },
                        else => {},
                    }
                }
            };

            const Impl = struct {
                receiver_ctx: ?*const anyopaque = null,
                emit_fn: ?CallbackFn = null,

                pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    self.receiver_ctx = ctx;
                    self.emit_fn = emit_fn;
                }

                pub fn clearEventCallback(self: *@This()) void {
                    self.receiver_ctx = null;
                    self.emit_fn = null;
                }

                pub fn emit(self: *@This()) !void {
                    const receiver_ctx = self.receiver_ctx orelse return error.MissingReceiver;
                    const emit_fn = self.emit_fn orelse return error.MissingReceiver;

                    const dns = [_]Addr{
                        Addr.from4(.{ 9, 9, 9, 9 }),
                        Addr.from4(.{ 1, 0, 0, 1 }),
                    };

                    emit_fn(receiver_ctx, .{
                        .netif_created = .{
                            .source_id = 52,
                            .netif_id = 3,
                            .netif_type = .ppp,
                            .name = "ppp0",
                        },
                    });
                    emit_fn(receiver_ctx, .{
                        .netif_up = .{
                            .source_id = 52,
                            .netif_id = 3,
                        },
                    });
                    emit_fn(receiver_ctx, .{
                        .dns_servers_changed = .{
                            .source_id = 52,
                            .netif_id = 3,
                            .dns_servers = dns[0..],
                        },
                    });
                    emit_fn(receiver_ctx, .{
                        .ppp_phase_changed = .{
                            .source_id = 52,
                            .netif_id = 3,
                            .phase = .running,
                        },
                    });
                    emit_fn(receiver_ctx, .{
                        .ppp_down = .{
                            .source_id = 52,
                            .netif_id = 3,
                            .reason = .carrier_lost,
                        },
                    });
                    emit_fn(receiver_ctx, .{
                        .netif_destroyed = .{
                            .source_id = 52,
                            .netif_id = 3,
                            .netif_type = .ppp,
                            .name = "ppp0",
                        },
                    });
                }
            };

            var sink = Sink{};
            var impl = Impl{};
            const netstack = NetStack.init(Impl, &impl);
            const receiver = EventReceiver.init(@ptrCast(&sink), struct {
                fn emitFn(ctx: *anyopaque, value: event.Event) void {
                    const sink_ptr: *Sink = @ptrCast(@alignCast(ctx));
                    const update = switch (value) {
                        .netstack_netif_created => |v| Update{
                            .netif_created = .{
                                .source_id = v.source_id,
                                .netif_id = v.netif_id,
                                .netif_type = v.netif_type,
                                .name = v.name(),
                                .ctx = v.ctx,
                            },
                        },
                        .netstack_netif_destroyed => |v| Update{
                            .netif_destroyed = .{
                                .source_id = v.source_id,
                                .netif_id = v.netif_id,
                                .netif_type = v.netif_type,
                                .name = v.name(),
                                .ctx = v.ctx,
                            },
                        },
                        .netstack_netif_up => |v| Update{ .netif_up = .{ .source_id = v.source_id, .netif_id = v.netif_id, .ctx = v.ctx } },
                        .netstack_dns_servers_changed => |v| Update{
                            .dns_servers_changed = .{
                                .source_id = v.source_id,
                                .netif_id = v.netif_id,
                                .dns_servers = v.dnsServers(),
                                .ctx = v.ctx,
                            },
                        },
                        .netstack_ppp_phase_changed => |v| Update{
                            .ppp_phase_changed = .{
                                .source_id = v.source_id,
                                .netif_id = v.netif_id,
                                .phase = v.phase,
                                .ctx = v.ctx,
                            },
                        },
                        .netstack_ppp_down => |v| Update{
                            .ppp_down = .{
                                .source_id = v.source_id,
                                .netif_id = v.netif_id,
                                .reason = v.reason,
                                .ctx = v.ctx,
                            },
                        },
                        else => return,
                    };
                    Sink.emitFn(@ptrCast(sink_ptr), update);
                }
            }.emitFn);

            netstack.setEventReceiver(&receiver);
            try impl.emit();

            try testing.expectEqual(@as(usize, 1), sink.created_count);
            try testing.expectEqual(@as(usize, 1), sink.destroyed_count);
            try testing.expectEqual(@as(usize, 1), sink.up_count);
            try testing.expectEqual(@as(usize, 1), sink.dns_count);
            try testing.expectEqual(@as(usize, 1), sink.ppp_down_count);
            try testing.expectEqual(@as(u32, 3), sink.last_netif_id);
            try testing.expectEqual(@as(usize, 2), sink.last_dns_count);
            try testing.expectEqual(@as(?NetifType, .ppp), sink.last_netif_type);
            try testing.expectEqual(@as(usize, 4), sink.last_netif_name_len);
            try testing.expectEqual(@as(?PppPhase, .running), sink.last_ppp_phase);
            try testing.expectEqual(@as(?PppDownReason, .carrier_lost), sink.last_ppp_down_reason);

            netstack.clearEventReceiver();
            try testing.expect(impl.receiver_ctx == null);
            try testing.expect(impl.emit_fn == null);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.makeEventCopiesDhcpAndDnsFields(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.makeEventCopiesNetifMetadata(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.makeEventMapsPppFields(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.registerAndEmitUpdatesThroughCallback(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
