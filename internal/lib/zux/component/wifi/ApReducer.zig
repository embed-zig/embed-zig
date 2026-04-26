const glib = @import("glib");
const wifi_event = @import("event.zig");
const wifi_state = @import("state.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");

const ApReducer = @This();
const ApState = wifi_state.Ap;
const MacAddr = wifi_event.MacAddr;
const Addr = wifi_event.Addr;

clients: glib.std.AutoHashMap(MacAddr, ClientRecord),

const ClientRecord = struct {
    ip: ?Addr = null,
    aid: u16 = 0,
};

pub fn init(allocator: glib.std.mem.Allocator) ApReducer {
    return .{
        .clients = glib.std.AutoHashMap(MacAddr, ClientRecord).init(allocator),
    };
}

pub fn reduce(self: *ApReducer, store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .wifi_ap_started => |value| {
            const Ctx = struct {
                reducer: *ApReducer,
                event_value: wifi_event.ApStarted,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *ApState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.active = true;
                    state.ssid_end = arg.event_value.ssid_end;
                    state.ssid_buf = arg.event_value.ssid_buf;
                    state.channel = arg.event_value.channel;
                    state.security = arg.event_value.security;
                    syncClientSummary(state, arg.reducer);
                }
            }.apply);
        },
        .wifi_ap_stopped => |value| {
            self.clients.clearRetainingCapacity();
            const Ctx = struct {
                reducer: *ApReducer,
                event_value: wifi_event.ApStopped,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *ApState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.active = false;
                    syncClientSummary(state, arg.reducer);
                }
            }.apply);
        },
        .wifi_ap_client_joined => |value| {
            const gop = try self.clients.getOrPut(value.client_mac);
            const previous_ip = if (gop.found_existing) gop.value_ptr.ip else value.client_ip;
            gop.value_ptr.* = .{
                .ip = previous_ip,
                .aid = value.aid,
            };

            const Ctx = struct {
                reducer: *ApReducer,
                event_value: wifi_event.ApClientJoined,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *ApState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.last_client_mac = arg.event_value.client_mac;
                    state.last_client_ip = arg.event_value.client_ip;
                    state.last_client_aid = arg.event_value.aid;
                    syncClientSummary(state, arg.reducer);
                }
            }.apply);
        },
        .wifi_ap_client_left => |value| {
            const previous_ip = if (self.clients.get(value.client_mac)) |record| record.ip else value.client_ip;
            _ = self.clients.remove(value.client_mac);

            const Ctx = struct {
                reducer: *ApReducer,
                event_value: wifi_event.ApClientLeft,
                previous_ip: ?Addr,
            };
            const payload: Ctx = .{
                .reducer = self,
                .event_value = value,
                .previous_ip = previous_ip,
            };
            store.invoke(payload, struct {
                fn apply(state: *ApState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.last_client_mac = arg.event_value.client_mac;
                    state.last_client_ip = arg.previous_ip;
                    state.last_client_aid = arg.event_value.aid;
                    syncClientSummary(state, arg.reducer);
                }
            }.apply);
        },
        .wifi_ap_lease_granted => |value| {
            const gop = try self.clients.getOrPut(value.client_mac);
            const previous_aid = if (gop.found_existing) gop.value_ptr.aid else 0;
            gop.value_ptr.* = .{
                .ip = value.client_ip,
                .aid = previous_aid,
            };

            const Ctx = struct {
                reducer: *ApReducer,
                event_value: wifi_event.ApLeaseGranted,
                previous_aid: u16,
            };
            const payload: Ctx = .{
                .reducer = self,
                .event_value = value,
                .previous_aid = previous_aid,
            };
            store.invoke(payload, struct {
                fn apply(state: *ApState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.last_client_mac = arg.event_value.client_mac;
                    state.last_client_ip = arg.event_value.client_ip;
                    state.last_client_aid = arg.previous_aid;
                    syncClientSummary(state, arg.reducer);
                }
            }.apply);
        },
        .wifi_ap_lease_released => |value| {
            if (self.clients.getPtr(value.client_mac)) |client| {
                client.ip = null;
            }

            const Ctx = struct {
                reducer: *ApReducer,
                event_value: wifi_event.ApLeaseReleased,
            };
            const payload: Ctx = .{ .reducer = self, .event_value = value };
            store.invoke(payload, struct {
                fn apply(state: *ApState, arg: Ctx) void {
                    state.source_id = arg.event_value.source_id;
                    state.last_client_mac = arg.event_value.client_mac;
                    state.last_client_ip = arg.event_value.client_ip;
                    syncClientSummary(state, arg.reducer);
                }
            }.apply);
        },
        else => return 0,
    }
    return 0;
}

pub fn deinit(self: *ApReducer) void {
    self.clients.deinit();
}

fn syncClientSummary(state: *ApState, self: *ApReducer) void {
    const max_count: usize = glib.std.math.maxInt(u16);
    state.client_count = @intCast(@min(self.clients.count(), max_count));
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn reduceTracksActiveClients() !void {
            const StoreObject = @import("../../store/Object.zig");

            const ApStore = StoreObject.make(lib, ApState, .wifi_ap);
            var store = ApStore.init(lib.testing.allocator, .{});
            defer store.deinit();
            var reducer = ApReducer.init(lib.testing.allocator);
            defer reducer.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};
            const emit = Emitter.init(&sink);

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_ap_started = .{
                        .source_id = 41,
                        .ssid_end = 6,
                        .ssid_buf = blk: {
                            var buf = [_]u8{0} ** wifi_event.max_ssid_len;
                            @memcpy(buf[0..6], "esp-ap");
                            break :blk buf;
                        },
                        .channel = 11,
                        .security = .wpa2,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_ap_client_joined = .{
                        .source_id = 41,
                        .client_mac = .{ 1, 2, 3, 4, 5, 6 },
                        .client_ip = null,
                        .aid = 3,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_ap_lease_granted = .{
                        .source_id = 41,
                        .client_mac = .{ 1, 2, 3, 4, 5, 6 },
                        .client_ip = Addr.from4(.{ 192, 168, 4, 10 }),
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_ap_client_joined = .{
                        .source_id = 41,
                        .client_mac = .{ 6, 5, 4, 3, 2, 1 },
                        .client_ip = Addr.from4(.{ 192, 168, 4, 11 }),
                        .aid = 4,
                    },
                },
            }, emit);

            store.tick();
            const active = store.get();
            try lib.testing.expect(active.active);
            try lib.testing.expectEqual(@as(u32, 41), active.source_id);
            try lib.testing.expectEqualStrings("esp-ap", active.ssid());
            try lib.testing.expectEqual(@as(u16, 2), active.client_count);
            try lib.testing.expectEqual(@as(u16, 4), active.last_client_aid);
            try lib.testing.expectEqual(Addr.from4(.{ 192, 168, 4, 11 }), active.last_client_ip.?);

            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_ap_client_left = .{
                        .source_id = 41,
                        .client_mac = .{ 1, 2, 3, 4, 5, 6 },
                        .client_ip = null,
                        .aid = 3,
                    },
                },
            }, emit);
            _ = try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .wifi_ap_stopped = .{
                        .source_id = 41,
                    },
                },
            }, emit);
            store.tick();
            const stopped = store.get();
            try lib.testing.expect(!stopped.active);
            try lib.testing.expectEqual(@as(u16, 0), stopped.client_count);
            try lib.testing.expectEqual(@as(?MacAddr, .{ 1, 2, 3, 4, 5, 6 }), stopped.last_client_mac);
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

            TestCase.reduceTracksActiveClients() catch |err| {
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
