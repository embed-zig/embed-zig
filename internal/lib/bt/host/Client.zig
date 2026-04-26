//! host.Client — higher-level client facade built on host.Central.

const glib = @import("glib");

const bt = @import("../../bt.zig");
const ConnMod = @import("client/Conn.zig");
const CharacteristicMod = @import("client/Characteristic.zig");
const SubscriptionMod = @import("client/Subscription.zig");

pub fn make(comptime lib: type) type {
    return struct {
        const Self = @This();

        pub const ConnectError = bt.Central.StartError || bt.Central.ConnectError;
        pub const GattError = bt.Central.GattError;
        pub const Subscription = SubscriptionMod.Subscription(lib, Self);
        pub const Characteristic = CharacteristicMod.Characteristic(lib, Self, Subscription);
        pub const Conn = ConnMod.Conn(lib, Self, Characteristic);

        const SubscriptionState = Subscription.State;

        allocator: lib.mem.Allocator,
        central: ?bt.Central = null,
        hook_installed: bool = false,
        mutex: lib.Thread.Mutex = .{},
        subscriptions: glib.std.ArrayListUnmanaged(*SubscriptionState) = .{},

        pub fn init(allocator: lib.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn bind(self: *Self, central: bt.Central) void {
            if (self.central == null) {
                self.central = central;
            } else {
                glib.std.debug.assert(sameCentral(self.central.?, central));
            }

            if (!self.hook_installed) {
                central.addEventHook(self, onCentralEvent);
                self.hook_installed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.hook_installed) {
                if (self.central) |central| {
                    central.removeEventHook(self, onCentralEvent);
                }
                self.hook_installed = false;
            }

            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.subscriptions.items) |state| {
                Subscription.detachClient(state);
                Subscription.releaseState(state);
            }
            self.subscriptions.deinit(self.allocator);
            self.central = null;
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

        pub fn attMtu(self: *Self, conn_handle: u16) u16 {
            return self.centralPtr().getAttMtu(conn_handle);
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
            errdefer Subscription.releaseState(sub.state);

            self.mutex.lock();
            self.subscriptions.append(self.allocator, sub.state) catch {
                self.mutex.unlock();
                return error.Unexpected;
            };
            Subscription.retainState(sub.state);
            self.mutex.unlock();
            errdefer {
                _ = self.unregisterSubscription(sub.state, false);
            }

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
            if (removed) {
                Subscription.releaseState(state);
            }
            return removed;
        }

        fn centralPtr(self: *Self) bt.Central {
            return self.central orelse @panic("host.Client used before bind()");
        }

        fn sameCentral(a: bt.Central, b: bt.Central) bool {
            return a.ptr == b.ptr and a.vtable == b.vtable;
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

        fn onCentralEvent(ctx: ?*anyopaque, event: bt.Central.Event) void {
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
                    Subscription.releaseState(state);
                    continue;
                }
                i += 1;
            }
        }
    };
}
