//! host.Client — higher-level client facade built on host.Central.

const std = @import("std");
const bt = @import("../../bt.zig");
const ConnMod = @import("client/Conn.zig");
const CharacteristicMod = @import("client/Characteristic.zig");
const SubscriptionMod = @import("client/Subscription.zig");

pub fn Client(comptime lib: type, comptime CentralType: type) type {
    return struct {
        const Self = @This();

        pub const ConnectError = bt.Central.StartError || bt.Central.ConnectError;
        pub const GattError = bt.Central.GattError;
        pub const Subscription = SubscriptionMod.Subscription(lib, Self);
        pub const Characteristic = CharacteristicMod.Characteristic(lib, Self, Subscription);
        pub const Conn = ConnMod.Conn(lib, Self, Characteristic);

        const SubscriptionState = Subscription.State;

        allocator: lib.mem.Allocator,
        central: ?*CentralType = null,
        hook_installed: bool = false,
        mutex: lib.Thread.Mutex = .{},
        subscriptions: std.ArrayListUnmanaged(*SubscriptionState) = .{},

        pub fn init(allocator: lib.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn bind(self: *Self, central: *CentralType) void {
            if (self.central == null) {
                self.central = central;
            } else {
                std.debug.assert(self.central.? == central);
            }

            if (!self.hook_installed) {
                central.addEventHook(self, onCentralEvent);
                self.hook_installed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.subscriptions.items) |state| {
                Subscription.close(state);
            }
            self.subscriptions.deinit(self.allocator);
            self.central = null;
            self.hook_installed = false;
        }

        pub fn connect(
            self: *Self,
            addr: bt.Central.BdAddr,
            addr_type: bt.Central.AddrType,
            params: bt.Central.ConnParams,
        ) ConnectError!Conn {
            try self.centralPtr().start();
            const info = try self.centralPtr().connect(addr, addr_type, params);
            return .{
                .client = self,
                .info = info,
            };
        }

        pub fn resolveCharacteristic(
            self: *Self,
            conn_handle: u16,
            svc_uuid: u16,
            characteristic_uuid: u16,
        ) GattError!bt.Central.DiscoveredChar {
            return self.centralPtr().resolveChar(conn_handle, svc_uuid, characteristic_uuid);
        }

        pub fn readAttr(
            self: *Self,
            conn_handle: u16,
            attr_handle: u16,
            out: []u8,
        ) GattError!usize {
            return self.centralPtr().gattRead(conn_handle, attr_handle, out);
        }

        pub fn writeAttr(
            self: *Self,
            conn_handle: u16,
            attr_handle: u16,
            data: []const u8,
        ) GattError!void {
            return self.centralPtr().gattWrite(conn_handle, attr_handle, data);
        }

        pub fn writeAttrNoResp(
            self: *Self,
            conn_handle: u16,
            attr_handle: u16,
            data: []const u8,
        ) GattError!void {
            return self.centralPtr().gattWriteNoResp(conn_handle, attr_handle, data);
        }

        pub fn disconnectConn(self: *Self, conn_handle: u16) void {
            self.centralPtr().disconnect(conn_handle);
        }

        pub fn subscribeAttr(
            self: *Self,
            conn_handle: u16,
            value_handle: u16,
            cccd_handle: u16,
            prefer_indications: bool,
        ) GattError!Subscription {
            const sub = Subscription.init(self.allocator, self, conn_handle, value_handle, cccd_handle) catch {
                return error.Unexpected;
            };
            errdefer Subscription.destroyState(sub.state);

            self.mutex.lock();
            self.subscriptions.append(self.allocator, sub.state) catch {
                self.mutex.unlock();
                return error.Unexpected;
            };
            self.mutex.unlock();
            errdefer _ = self.unregisterSubscription(sub.state, false);

            if (prefer_indications) {
                try self.centralPtr().subscribeIndications(conn_handle, cccd_handle);
            } else {
                try self.centralPtr().subscribe(conn_handle, cccd_handle);
            }
            return sub;
        }

        pub fn unregisterSubscription(self: *Self, state: *SubscriptionState, disable_remote: bool) bool {
            self.mutex.lock();
            const removed = self.removeSubscriptionLocked(state);
            self.mutex.unlock();

            if (disable_remote and removed) {
                if (self.central) |central| {
                    central.unsubscribe(state.conn_handle, state.cccd_handle) catch {};
                }
            }

            Subscription.close(state);
            return removed;
        }

        fn centralPtr(self: *Self) *CentralType {
            return self.central orelse @panic("host.Client used before Host.client() binding");
        }

        fn removeSubscriptionLocked(self: *Self, state: *SubscriptionState) bool {
            for (self.subscriptions.items, 0..) |item, i| {
                if (item == state) {
                    _ = self.subscriptions.orderedRemove(i);
                    return true;
                }
            }
            return false;
        }

        fn onCentralEvent(ctx: ?*anyopaque, event: bt.Central.CentralEvent) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .notification => |notif| self.dispatchNotification(notif),
                .disconnected => |conn_handle| self.handleDisconnect(conn_handle),
                else => {},
            }
        }

        fn dispatchNotification(self: *Self, notif: bt.Central.NotificationData) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.subscriptions.items) |state| {
                if (Subscription.matches(state, notif.conn_handle, notif.attr_handle)) {
                    Subscription.push(state, notif);
                }
            }
        }

        fn handleDisconnect(self: *Self, conn_handle: u16) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var i: usize = 0;
            while (i < self.subscriptions.items.len) {
                const state = self.subscriptions.items[i];
                if (state.conn_handle == conn_handle) {
                    _ = self.subscriptions.orderedRemove(i);
                    Subscription.close(state);
                    continue;
                }
                i += 1;
            }
        }
    };
}

test "bt/integration_tests/host/Client_connect_read_write_and_subscribe" {
    const Mocker = bt.Mocker(std);
    const TestChannel = @import("embed_std").sync.Channel;
    const Host = @import("../Host.zig").Host(std, TestChannel);

    const chars = [_]bt.Peripheral.CharDef{
        bt.Peripheral.Char(0x2A37, .{
            .read = true,
            .write = true,
            .write_without_response = true,
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
                .write => {
                    self.len = @min(self.value.len, req.data.len);
                    if (self.len > 0) @memcpy(self.value[0..self.len], req.data[0..self.len]);
                    rw.ok();
                },
                .write_without_response => {
                    self.len = @min(self.value.len, req.data.len);
                    if (self.len > 0) @memcpy(self.value[0..self.len], req.data[0..self.len]);
                },
            }
        }
    };

    const PeripheralConnState = struct {
        mutex: std.Thread.Mutex = .{},
        conn_handle: u16 = 0,

        fn onEvent(ctx: ?*anyopaque, evt: bt.Peripheral.PeripheralEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            switch (evt) {
                .connected => |info| self.conn_handle = info.conn_handle,
                .disconnected => |_| self.conn_handle = 0,
                else => {},
            }
        }

        fn waitForConnHandle(self: *@This()) !u16 {
            var waited_ms: u32 = 0;
            while (waited_ms <= 1000) : (waited_ms += 1) {
                self.mutex.lock();
                const conn_handle = self.conn_handle;
                self.mutex.unlock();
                if (conn_handle != 0) return conn_handle;
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            return error.NoPeripheralConnHandle;
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

    var peripheral = peripheral_host.peripheral();
    peripheral.setConfig(.{
        .services = &services,
    });

    var handler_state = HandlerState.init();
    var peripheral_conn_state = PeripheralConnState{};
    peripheral.setRequestHandler(&handler_state, HandlerState.handle);
    peripheral.addEventHook(&peripheral_conn_state, PeripheralConnState.onEvent);
    try peripheral.start();
    defer peripheral.stop();
    try peripheral.startAdvertising(.{
        .device_name = "mock-hr",
        .service_uuids = &.{0x180D},
    });
    defer peripheral.stopAdvertising();

    const addr = peripheral.getAddr() orelse return error.NoPeripheralAddr;
    const client = central_host.client();
    var conn = try client.connect(addr, .public, .{});
    var characteristic = try conn.characteristic(0x180D, 0x2A37);

    var buf: [32]u8 = undefined;
    const n = try characteristic.read(&buf);
    try std.testing.expectEqualSlices(u8, "72", buf[0..n]);

    try characteristic.write("88");
    try std.testing.expectEqual(@as(?bt.Peripheral.Operation, .write), handler_state.last_op);
    try std.testing.expectEqualSlices(u8, "88", handler_state.value[0..handler_state.len]);

    try characteristic.writeNoResp("91");
    try std.testing.expectEqual(@as(?bt.Peripheral.Operation, .write_without_response), handler_state.last_op);
    try std.testing.expectEqualSlices(u8, "91", handler_state.value[0..handler_state.len]);

    var sub = try characteristic.subscribe();
    defer sub.deinit();

    const peripheral_conn_handle = try peripheral_conn_state.waitForConnHandle();
    try peripheral.notify(peripheral_conn_handle, 0x2A37, "99");
    const msg = (try sub.next(null)) orelse return error.NoSubscriptionMessage;
    try std.testing.expectEqual(conn.connHandle(), msg.conn_handle);
    try std.testing.expectEqual(characteristic.value_handle, msg.attr_handle);
    try std.testing.expectEqualSlices(u8, "99", msg.payload());
}
