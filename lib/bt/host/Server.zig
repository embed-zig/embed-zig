//! host.Server — higher-level server facade built on host.Peripheral.

const std = @import("std");
const bt = @import("../../bt.zig");
const att = @import("att.zig");
const SubscriptionMod = @import("server/Subscription.zig");
const XferServerMod = @import("xfer/Server.zig");
const xfer_chunk = @import("xfer/Chunk.zig");

pub fn Server(comptime lib: type, comptime Channel: fn (type) type, comptime PeripheralType: type) type {
    return struct {
        const Self = @This();
        const XferImpl = XferServerMod.Server(lib, Self);

        pub const Request = bt.Peripheral.Request;
        pub const ResponseWriter = bt.Peripheral.ResponseWriter;
        pub const ReadXRequest = XferImpl.ReadXRequest;
        pub const WriteXRequest = XferImpl.WriteXRequest;
        pub const ReadXResponseWriter = XferImpl.ReadXResponseWriter;
        pub const HandlerFn = *const fn (?*anyopaque, *const Request, *ResponseWriter) void;
        pub const ReadXHandlerFn = XferImpl.ReadXHandlerFn;
        pub const WriteXHandlerFn = XferImpl.WriteXHandlerFn;
        pub const XHandler = XferImpl.XHandler;
        pub const ServerMux = @import("xfer/ServerMux.zig").ServerMux(lib, Self);
        pub const Subscription = SubscriptionMod.Subscription(lib, Self);
        pub const PushMode = enum {
            notify,
            indicate,
        };
        pub const HandleError = error{Unexpected};
        pub const AcceptError = error{
            TimedOut,
        };
        pub const PushError = bt.Peripheral.GattError;

        const SubscriptionState = Subscription.State;
        const AcceptCh = Channel(*SubscriptionState);
        const CharKey = struct {
            service_uuid: u16,
            char_uuid: u16,
        };
        const PlainRoute = struct {
            handler: HandlerFn,
            ctx: ?*anyopaque,
        };
        const RouteKind = union(enum) {
            plain: PlainRoute,
            xfer: void,
        };
        const Route = struct {
            kind: RouteKind,
        };
        const ConnState = struct {
            subscriptions: lib.AutoHashMapUnmanaged(CharKey, *SubscriptionState) = .{},

            fn isEmpty(self: *const ConnState) bool {
                return self.subscriptions.count() == 0;
            }

            fn deinit(self: *ConnState, allocator: lib.mem.Allocator) void {
                var subs = self.subscriptions.iterator();
                while (subs.next()) |entry| {
                    const state = entry.value_ptr.*;
                    Subscription.close(state);
                    Subscription.release(state);
                }

                self.subscriptions.deinit(allocator);
                self.* = .{};
            }
        };

        allocator: lib.mem.Allocator,
        peripheral: ?*PeripheralType = null,
        hook_installed: bool = false,
        mutex: lib.Thread.Mutex = .{},
        cond: lib.Thread.Condition = .{},
        routes: lib.AutoHashMapUnmanaged(CharKey, Route) = .{},
        conns: lib.AutoHashMapUnmanaged(u16, ConnState) = .{},
        xfer_impl: XferImpl,
        accept_ch: AcceptCh,
        queued_count: usize = 0,
        enqueue_inflight: usize = 0,
        closed: bool = false,

        pub fn init(allocator: lib.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
                .xfer_impl = XferImpl.init(allocator),
                .accept_ch = try AcceptCh.make(allocator, 64),
            };
        }

        pub fn bind(self: *Self, peripheral: *PeripheralType) void {
            if (self.peripheral == null) {
                self.peripheral = peripheral;
            } else {
                std.debug.assert(self.peripheral.? == peripheral);
            }

            if (!self.hook_installed) {
                self.xfer_impl.bind(self);
                peripheral.addEventHook(self, onPeripheralEvent);
                peripheral.addSubscriptionHook(self, onSubscriptionChanged);
                peripheral.setRequestHandler(self, onRequest);
                self.hook_installed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.hook_installed) {
                if (self.peripheral) |peripheral| {
                    peripheral.removeEventHook(self, onPeripheralEvent);
                    peripheral.removeSubscriptionHook(self, onSubscriptionChanged);
                    peripheral.clearRequestHandler();
                }
                self.hook_installed = false;
            }

            self.mutex.lock();
            self.closed = true;
            self.cond.broadcast();
            self.mutex.unlock();

            self.accept_ch.close();

            self.mutex.lock();
            while (self.enqueue_inflight != 0) {
                self.cond.wait(&self.mutex);
            }
            var conn_iter = self.conns.iterator();
            while (conn_iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.conns.deinit(self.allocator);
            self.routes.deinit(self.allocator);
            self.mutex.unlock();
            while (true) {
                const recv_res = self.accept_ch.recv() catch break;
                if (!recv_res.ok) break;
                Subscription.release(recv_res.value);
            }
            self.accept_ch.deinit();
            self.xfer_impl.deinit();

            self.peripheral = null;
        }

        pub fn start(self: *Self) bt.Peripheral.StartError!void {
            return self.peripheralPtr().start();
        }

        pub fn stop(self: *Self) void {
            self.peripheralPtr().stop();
        }

        pub fn setConfig(self: *Self, config: bt.Peripheral.GattConfig) void {
            self.peripheralPtr().setConfig(config);
        }

        pub fn startAdvertising(self: *Self, config: bt.Peripheral.AdvConfig) bt.Peripheral.AdvError!void {
            return self.peripheralPtr().startAdvertising(config);
        }

        pub fn stopAdvertising(self: *Self) void {
            self.peripheralPtr().stopAdvertising();
        }

        pub fn getAddr(self: *Self) ?bt.Peripheral.BdAddr {
            return self.peripheralPtr().getAddr();
        }

        pub fn disconnect(self: *Self, conn_handle: u16) void {
            self.peripheralPtr().disconnect(conn_handle);
        }

        pub fn handle(self: *Self, service_uuid: u16, char_uuid: u16, handler: HandlerFn, ctx: ?*anyopaque) HandleError!void {
            return self.registerPlainRoute(service_uuid, char_uuid, handler, ctx);
        }

        /// Registers logical xfer handlers for client `readX` / `writeX` traffic.
        pub fn handleX(self: *Self, service_uuid: u16, char_uuid: u16, handler: XHandler, ctx: ?*anyopaque) HandleError!void {
            return self.registerXferRoute(service_uuid, char_uuid, handler, ctx);
        }

        pub fn accept(self: *Self, timeout_ms: ?u32) AcceptError!?Subscription {
            while (true) {
                self.mutex.lock();
                while (self.queued_count == 0 and !self.closed) {
                    if (timeout_ms) |ms| {
                        self.cond.timedWait(&self.mutex, @as(u64, ms) * lib.time.ns_per_ms) catch |err| switch (err) {
                            error.Timeout => {
                                self.mutex.unlock();
                                return error.TimedOut;
                            },
                        };
                    } else {
                        self.cond.wait(&self.mutex);
                    }
                }

                if (self.queued_count == 0) {
                    self.mutex.unlock();
                    return null;
                }
                self.queued_count -= 1;
                self.mutex.unlock();

                const recv_res = self.accept_ch.recv() catch {
                    self.mutex.lock();
                    self.queued_count += 1;
                    self.mutex.unlock();
                    return null;
                };
                if (!recv_res.ok) {
                    self.mutex.lock();
                    self.queued_count += 1;
                    self.mutex.unlock();
                    return null;
                }

                const state = recv_res.value;
                state.mutex.lock();
                const closed = state.closed;
                state.mutex.unlock();
                if (closed) {
                    Subscription.release(state);
                    continue;
                }
                return .{ .state = state };
            }
        }

        pub fn unregisterSubscription(self: *Self, state: *SubscriptionState) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.removeSubscriptionLocked(state);
        }

        pub fn push(self: *Self, conn_handle: u16, char_uuid: u16, mode: PushMode, data: []const u8) PushError!void {
            return switch (mode) {
                .notify => self.peripheralPtr().notify(conn_handle, char_uuid, data),
                .indicate => self.peripheralPtr().indicate(conn_handle, char_uuid, data),
            };
        }

        fn peripheralPtr(self: *Self) *PeripheralType {
            return self.peripheral orelse @panic("host.Server used before Host.server() binding");
        }

        fn charKey(service_uuid: u16, char_uuid: u16) CharKey {
            return .{
                .service_uuid = service_uuid,
                .char_uuid = char_uuid,
            };
        }

        fn getOrPutConnLocked(self: *Self, conn_handle: u16) !*ConnState {
            const gop = try self.conns.getOrPut(self.allocator, conn_handle);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            return gop.value_ptr;
        }

        fn pruneConnIfEmptyLocked(self: *Self, conn_handle: u16) void {
            const conn = self.conns.getPtr(conn_handle) orelse return;
            if (conn.isEmpty()) {
                _ = self.conns.remove(conn_handle);
            }
        }

        fn takeConnLocked(self: *Self, conn_handle: u16) ?ConnState {
            const conn = self.conns.get(conn_handle) orelse return null;
            _ = self.conns.remove(conn_handle);
            return conn;
        }

        fn onRequest(ctx: ?*anyopaque, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.dispatchRequest(req, rw);
        }

        fn dispatchRequest(self: *Self, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            self.mutex.lock();
            const route = self.findRouteLocked(req.service_uuid, req.char_uuid);
            self.mutex.unlock();

            if (route) |matched| {
                switch (matched.kind) {
                    .plain => |plain| plain.handler(plain.ctx, req, rw),
                    .xfer => {
                        if (self.xfer_impl.dispatchRequest(req, rw)) return;
                        rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    },
                }
                return;
            }

            rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
        }

        fn onPeripheralEvent(ctx: ?*anyopaque, event: bt.Peripheral.PeripheralEvent) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .mtu_changed => |info| self.xfer_impl.handleMtuChanged(info.conn_handle, info.mtu),
                .disconnected => |conn_handle| {
                    self.handleDisconnect(conn_handle);
                    self.xfer_impl.handleDisconnect(conn_handle);
                },
                else => {},
            }
        }

        fn onSubscriptionChanged(ctx: ?*anyopaque, info: PeripheralType.SubscriptionInfo) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.handleSubscriptionChanged(info);
        }

        fn handleSubscriptionChanged(self: *Self, info: PeripheralType.SubscriptionInfo) void {
            self.xfer_impl.handleSubscriptionChanged(info);

            self.mutex.lock();
            self.closeMatchingLocked(info.conn_handle, info.service_uuid, info.char_uuid);
            if (self.closed or info.cccd_value == 0) {
                self.mutex.unlock();
                return;
            }

            const is_xfer = if (self.findRouteLocked(info.service_uuid, info.char_uuid)) |route|
                switch (route.kind) {
                    .plain => false,
                    .xfer => true,
                }
            else
                false;
            if (is_xfer) {
                self.mutex.unlock();
                return;
            }

            const sub = Subscription.init(
                self.allocator,
                self,
                info.conn_handle,
                info.service_uuid,
                info.char_uuid,
                info.cccd_value,
            ) catch {
                self.mutex.unlock();
                return;
            };

            const conn = self.getOrPutConnLocked(info.conn_handle) catch {
                self.mutex.unlock();
                Subscription.release(sub.state);
                return;
            };
            conn.subscriptions.put(self.allocator, charKey(info.service_uuid, info.char_uuid), sub.state) catch {
                self.mutex.unlock();
                Subscription.release(sub.state);
                return;
            };
            Subscription.retain(sub.state);
            self.enqueue_inflight += 1;
            self.mutex.unlock();

            const send_res = self.accept_ch.send(sub.state) catch {
                self.mutex.lock();
                self.enqueue_inflight -= 1;
                self.cond.broadcast();
                if (self.removeSubscriptionLocked(sub.state)) {
                    Subscription.close(sub.state);
                    Subscription.release(sub.state);
                }
                self.mutex.unlock();
                Subscription.release(sub.state);
                return;
            };

            self.mutex.lock();
            self.enqueue_inflight -= 1;
            self.cond.broadcast();
            if (!self.closed and send_res.ok) {
                self.queued_count += 1;
                self.cond.signal();
            } else {
                if (self.removeSubscriptionLocked(sub.state)) {
                    Subscription.close(sub.state);
                    Subscription.release(sub.state);
                }
                self.mutex.unlock();
                Subscription.release(sub.state);
                return;
            }
            self.mutex.unlock();
        }

        fn handleDisconnect(self: *Self, conn_handle: u16) void {
            self.mutex.lock();
            if (self.takeConnLocked(conn_handle)) |conn_state| {
                var conn = conn_state;
                conn.deinit(self.allocator);
            }
            self.mutex.unlock();
        }

        fn closeMatchingLocked(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) void {
            const conn = self.conns.getPtr(conn_handle) orelse return;
            const key = charKey(service_uuid, char_uuid);

            if (conn.subscriptions.get(key)) |state| {
                _ = conn.subscriptions.remove(key);
                Subscription.close(state);
                Subscription.release(state);
            }
            self.pruneConnIfEmptyLocked(conn_handle);
        }

        fn removeSubscriptionLocked(self: *Self, state: *SubscriptionState) bool {
            const conn = self.conns.getPtr(state.conn_handle) orelse return false;
            const key = charKey(state.service_uuid, state.char_uuid);
            const existing = conn.subscriptions.get(key) orelse return false;
            if (existing != state) {
                return false;
            }
            _ = conn.subscriptions.remove(key);
            self.pruneConnIfEmptyLocked(state.conn_handle);
            return true;
        }

        fn registerPlainRoute(
            self: *Self,
            service_uuid: u16,
            char_uuid: u16,
            handler: HandlerFn,
            ctx: ?*anyopaque,
        ) HandleError!void {
            self.xfer_impl.removeRoute(service_uuid, char_uuid);
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.upsertRouteLocked(service_uuid, char_uuid, .{
                .plain = .{
                    .handler = handler,
                    .ctx = ctx,
                },
            });
        }

        fn registerXferRoute(
            self: *Self,
            service_uuid: u16,
            char_uuid: u16,
            handler: XHandler,
            ctx: ?*anyopaque,
        ) HandleError!void {
            try self.xfer_impl.handle(service_uuid, char_uuid, handler, ctx);
            self.mutex.lock();
            self.upsertRouteLocked(service_uuid, char_uuid, .{ .xfer = {} }) catch |err| {
                self.mutex.unlock();
                self.xfer_impl.removeRoute(service_uuid, char_uuid);
                return err;
            };
            self.mutex.unlock();
        }

        fn upsertRouteLocked(
            self: *Self,
            service_uuid: u16,
            char_uuid: u16,
            kind: RouteKind,
        ) HandleError!void {
            self.routes.put(self.allocator, charKey(service_uuid, char_uuid), .{
                .kind = kind,
            }) catch return error.Unexpected;
        }

        fn findRouteLocked(self: *Self, service_uuid: u16, char_uuid: u16) ?Route {
            return self.routes.get(charKey(service_uuid, char_uuid));
        }
    };
}

test "bt/integration_tests/host/Server_handle_and_accept_subscription" {
    const Mocker = bt.Mocker(std);
    const TestChannel = @import("embed_std").sync.Channel;
    const Host = @import("../Host.zig").Host(std, TestChannel);

    const chars = [_]bt.Peripheral.CharDef{
        bt.Peripheral.Char(0x2A37, .{
            .read = true,
            .write = true,
            .notify = true,
        }),
    };
    const services = [_]bt.Peripheral.ServiceDef{
        bt.Peripheral.Service(0x180D, &chars),
    };

    const HandlerState = struct {
        value: [32]u8 = [_]u8{0} ** 32,
        len: usize = 0,
        last_op: ?bt.Peripheral.Operation = null,

        fn init() @This() {
            var self = @This(){};
            @memcpy(self.value[0..2], "72");
            self.len = 2;
            return self;
        }

        fn handle(ctx: ?*anyopaque, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.last_op = req.op;
            switch (req.op) {
                .read => {
                    rw.write(self.value[0..self.len]);
                    rw.ok();
                },
                .write, .write_without_response => {
                    self.len = @min(self.value.len, req.data.len);
                    if (self.len > 0) @memcpy(self.value[0..self.len], req.data[0..self.len]);
                    rw.ok();
                },
            }
        }
    };

    var mocker = Mocker.init(std.testing.allocator, .{});
    defer mocker.deinit();

    var central_host: Host = try mocker.createHost(.{});
    defer central_host.deinit();
    var peripheral_host: Host = try mocker.createHost(.{
        .hci = .{
            .controller_addr = .{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 },
            .peer_addr = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
        },
    });
    defer peripheral_host.deinit();

    var server = peripheral_host.server();
    server.setConfig(.{
        .services = &services,
    });

    var handler_state = HandlerState.init();
    try server.handle(0x180D, 0x2A37, HandlerState.handle, &handler_state);
    try server.start();
    defer server.stop();
    try server.startAdvertising(.{
        .device_name = "mock-hr",
        .service_uuids = &.{0x180D},
    });
    defer server.stopAdvertising();

    const addr = server.getAddr() orelse return error.NoPeripheralAddr;
    const client = central_host.client();
    var conn = try client.connect(addr, .public, .{});
    var characteristic = try conn.characteristic(0x180D, 0x2A37);

    var buf: [32]u8 = undefined;
    const n = try characteristic.read(&buf);
    try std.testing.expectEqualSlices(u8, "72", buf[0..n]);

    try characteristic.write("88");
    try std.testing.expectEqual(@as(?bt.Peripheral.Operation, .write), handler_state.last_op);
    try std.testing.expectEqualSlices(u8, "88", handler_state.value[0..handler_state.len]);

    var client_sub = try characteristic.subscribe();
    defer client_sub.deinit();

    var server_sub = (try server.accept(1000)) orelse return error.NoServerSubscription;
    defer server_sub.deinit();
    try std.testing.expect(server_sub.connHandle() != 0);
    try std.testing.expectEqual(@as(u16, 0x180D), server_sub.serviceUuid());
    try std.testing.expectEqual(@as(u16, 0x2A37), server_sub.charUuid());
    try std.testing.expect(server_sub.canNotify());

    try server_sub.write("99");
    const msg = (try client_sub.next(1000)) orelse return error.NoSubscriptionMessage;
    try std.testing.expectEqual(conn.connHandle(), msg.conn_handle);
    try std.testing.expectEqual(characteristic.value_handle, msg.attr_handle);
    try std.testing.expectEqualSlices(u8, "99", msg.payload());
}

test "bt/integration_tests/host/Server_handleX_reads_and_writes_without_accept_queue" {
    const Mocker = bt.Mocker(std);
    const TestChannel = @import("embed_std").sync.Channel;
    const Host = @import("../Host.zig").Host(std, TestChannel);
    const ServerType = @FieldType(Host, "server_impl");
    const ReadXRequest = ServerType.ReadXRequest;
    const WriteXRequest = ServerType.WriteXRequest;
    const ReadXResponseWriter = ServerType.ReadXResponseWriter;
    const negotiated_mtu: u16 = 64;

    const chars = [_]bt.Peripheral.CharDef{
        bt.Peripheral.Char(0x2A57, .{
            .write = true,
            .write_without_response = true,
            .notify = true,
        }),
    };
    const services = [_]bt.Peripheral.ServiceDef{
        bt.Peripheral.Service(0x180D, &chars),
    };

    const HandlerState = struct {
        read_value: [600]u8 = undefined,
        write_value: [600]u8 = undefined,
        write_len: usize = 0,
        last_op: ?enum {
            read_x,
            write_x,
        } = null,

        fn init() @This() {
            var self = @This(){};
            for (&self.read_value, 0..) |*byte, i| {
                byte.* = @intCast(i % 251);
            }
            return self;
        }

        fn handleRead(ctx: ?*anyopaque, req: *const ReadXRequest, rw: *ReadXResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = req;
            self.last_op = .read_x;
            rw.write(&self.read_value);
        }

        fn handleWrite(ctx: ?*anyopaque, req: *const WriteXRequest) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.last_op = .write_x;
            self.write_len = @min(self.write_value.len, req.data.len);
            @memcpy(self.write_value[0..self.write_len], req.data[0..self.write_len]);
        }
    };

    var mocker = Mocker.init(std.testing.allocator, .{});
    defer mocker.deinit();

    var central_host: Host = try mocker.createHost(.{});
    defer central_host.deinit();
    var peripheral_host: Host = try mocker.createHost(.{
        .hci = .{
            .controller_addr = .{ 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6 },
            .peer_addr = .{ 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 },
            .mtu = negotiated_mtu,
        },
    });
    defer peripheral_host.deinit();

    var server = peripheral_host.server();
    server.setConfig(.{
        .services = &services,
    });

    var handler_state = HandlerState.init();
    try server.handleX(0x180D, 0x2A57, .{
        .read = HandlerState.handleRead,
        .write = HandlerState.handleWrite,
    }, &handler_state);
    try server.start();
    defer server.stop();
    try server.startAdvertising(.{
        .device_name = "mock-xfer",
        .service_uuids = &.{0x180D},
    });
    defer server.stopAdvertising();

    const addr = server.getAddr() orelse return error.NoPeripheralAddr;
    const client = central_host.client();
    var conn = try client.connect(addr, .public, .{});
    var characteristic = try conn.characteristic(0x180D, 0x2A57);
    try std.testing.expectEqual(negotiated_mtu, characteristic.attMtu());

    try std.testing.expectError(error.AttError, characteristic.write(&xfer_chunk.read_start_magic));

    var sub = try characteristic.subscribe();
    try std.testing.expectError(error.TimedOut, server.accept(100));
    sub.deinit();

    const read_back = try characteristic.readX(std.testing.allocator);
    defer std.testing.allocator.free(read_back);
    try std.testing.expectEqualSlices(u8, &handler_state.read_value, read_back);
    try std.testing.expectEqual(@as(@TypeOf(handler_state.last_op), .read_x), handler_state.last_op);

    var write_value: [600]u8 = undefined;
    for (&write_value, 0..) |*byte, i| {
        byte.* = @intCast((i * 7) % 251);
    }
    try characteristic.writeX(&write_value);
    try std.testing.expectEqual(@as(@TypeOf(handler_state.last_op), .write_x), handler_state.last_op);
    try std.testing.expectEqualSlices(u8, &write_value, handler_state.write_value[0..handler_state.write_len]);
}

test "bt/integration_tests/host/ServerMux_routes_topics_over_single_characteristic" {
    const Mocker = bt.Mocker(std);
    const TestChannel = @import("embed_std").sync.Channel;
    const Host = @import("../Host.zig").Host(std, TestChannel);
    const ServerType = @FieldType(Host, "server_impl");
    const MuxRequest = ServerType.ServerMux.Request;
    const ReadXResponseWriter = ServerType.ReadXResponseWriter;

    const topic_alpha: xfer_chunk.Topic = 0x0102030405060708;
    const topic_beta: xfer_chunk.Topic = 0x1112131415161718;
    const topic_missing: xfer_chunk.Topic = 0x2122232425262728;

    const chars = [_]bt.Peripheral.CharDef{
        bt.Peripheral.Char(0x2A57, .{
            .write = true,
            .write_without_response = true,
            .notify = true,
        }),
    };
    const services = [_]bt.Peripheral.ServiceDef{
        bt.Peripheral.Service(0x180D, &chars),
    };

    const HandlerState = struct {
        calls: usize = 0,
        last_topic: ?xfer_chunk.Topic = null,

        fn handleAlpha(ctx: ?*anyopaque, req: *const MuxRequest, rw: *ReadXResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.last_topic = req.topic;
            rw.write("alpha");
        }

        fn handleBeta(ctx: ?*anyopaque, req: *const MuxRequest, rw: *ReadXResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.last_topic = req.topic;
            rw.write("beta");
        }
    };

    var mocker = Mocker.init(std.testing.allocator, .{});
    defer mocker.deinit();

    var central_host: Host = try mocker.createHost(.{});
    defer central_host.deinit();
    var peripheral_host: Host = try mocker.createHost(.{
        .hci = .{
            .controller_addr = .{ 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6 },
            .peer_addr = .{ 0x41, 0x42, 0x43, 0x44, 0x45, 0x46 },
        },
    });
    defer peripheral_host.deinit();

    var server = peripheral_host.server();
    server.setConfig(.{
        .services = &services,
    });

    var mux = ServerType.ServerMux.init(std.testing.allocator);
    defer mux.deinit();
    var handler_state = HandlerState{};
    try mux.handle(topic_alpha, HandlerState.handleAlpha, &handler_state);
    try mux.handle(topic_beta, HandlerState.handleBeta, &handler_state);
    try server.handleX(0x180D, 0x2A57, mux.xHandler(), &mux);

    try server.start();
    defer server.stop();
    try server.startAdvertising(.{
        .device_name = "mock-mux",
        .service_uuids = &.{0x180D},
    });
    defer server.stopAdvertising();

    const addr = server.getAddr() orelse return error.NoPeripheralAddr;
    const client = central_host.client();
    var conn = try client.connect(addr, .public, .{});
    var characteristic = try conn.characteristic(0x180D, 0x2A57);

    try std.testing.expectError(error.AttError, characteristic.write(&xfer_chunk.read_start_magic));

    const alpha = try characteristic.get(topic_alpha, std.testing.allocator);
    defer std.testing.allocator.free(alpha);
    try std.testing.expectEqualSlices(u8, "alpha", alpha);
    try std.testing.expectEqual(@as(?xfer_chunk.Topic, topic_alpha), handler_state.last_topic);

    const beta = try characteristic.get(topic_beta, std.testing.allocator);
    defer std.testing.allocator.free(beta);
    try std.testing.expectEqualSlices(u8, "beta", beta);
    try std.testing.expectEqual(@as(?xfer_chunk.Topic, topic_beta), handler_state.last_topic);
    try std.testing.expectEqual(@as(usize, 2), handler_state.calls);

    try std.testing.expectError(error.AttError, characteristic.get(topic_missing, std.testing.allocator));
    try std.testing.expectError(error.TimedOut, server.accept(100));
}

test "bt/integration_tests/host/Server_disconnect_cleans_only_that_connection_state" {
    const Mocker = bt.Mocker(std);
    const TestChannel = @import("embed_std").sync.Channel;
    const Host = @import("../Host.zig").Host(std, TestChannel);
    const ServerType = @FieldType(Host, "server_impl");

    const chars = [_]bt.Peripheral.CharDef{
        bt.Peripheral.Char(0x2A37, .{
            .notify = true,
        }),
    };
    const services = [_]bt.Peripheral.ServiceDef{
        bt.Peripheral.Service(0x180D, &chars),
    };

    var mocker = Mocker.init(std.testing.allocator, .{});
    defer mocker.deinit();

    var central_a: Host = try mocker.createHost(.{});
    defer central_a.deinit();
    var central_b: Host = try mocker.createHost(.{});
    defer central_b.deinit();
    var peripheral_host: Host = try mocker.createHost(.{
        .hci = .{
            .controller_addr = .{ 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6 },
            .peer_addr = .{ 0x31, 0x32, 0x33, 0x34, 0x35, 0x36 },
        },
    });
    defer peripheral_host.deinit();

    var server = peripheral_host.server();
    server.setConfig(.{
        .services = &services,
    });
    try server.start();
    defer server.stop();
    try server.startAdvertising(.{
        .device_name = "mock-disconnect",
        .service_uuids = &.{0x180D},
    });
    defer server.stopAdvertising();

    const addr = server.getAddr() orelse return error.NoPeripheralAddr;

    const client_a = central_a.client();
    var conn_a = try client_a.connect(addr, .public, .{});
    var char_a = try conn_a.characteristic(0x180D, 0x2A37);
    var client_sub_a = try char_a.subscribe();
    defer client_sub_a.deinit();

    const client_b = central_b.client();
    var conn_b = try client_b.connect(addr, .public, .{});
    var char_b = try conn_b.characteristic(0x180D, 0x2A37);
    var client_sub_b = try char_b.subscribe();
    defer client_sub_b.deinit();

    var server_sub_1 = (try server.accept(1000)) orelse return error.NoServerSubscription;
    defer server_sub_1.deinit();
    var server_sub_2 = (try server.accept(1000)) orelse return error.NoServerSubscription;
    defer server_sub_2.deinit();

    const closed_sub: *ServerType.Subscription = if (server_sub_1.connHandle() == conn_a.connHandle())
        &server_sub_1
    else
        &server_sub_2;
    const live_sub: *ServerType.Subscription = if (server_sub_1.connHandle() == conn_b.connHandle())
        &server_sub_1
    else
        &server_sub_2;

    conn_a.disconnect();

    var closed = false;
    for (0..20) |_| {
        closed_sub.write("stale") catch |err| switch (err) {
            error.Closed => {
                closed = true;
                break;
            },
            else => return err,
        };
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(closed);

    try live_sub.write("ok");
    const msg = (try client_sub_b.next(1000)) orelse return error.NoSubscriptionMessage;
    try std.testing.expectEqual(conn_b.connHandle(), msg.conn_handle);
    try std.testing.expectEqualSlices(u8, "ok", msg.payload());
}
