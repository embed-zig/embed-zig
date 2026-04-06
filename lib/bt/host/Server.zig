//! host.Server — higher-level server facade built on host.Peripheral.

const std = @import("std");
const bt = @import("../../bt.zig");
const att = @import("att.zig");

const root = @This();

pub fn Subscription(comptime lib: type, comptime ServerType: type) type {
    return struct {
        pub const WriteError = bt.Peripheral.GattError || error{
            Closed,
            UnsupportedMode,
        };

        pub const State = struct {
            allocator: lib.mem.Allocator,
            server: *ServerType,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            cccd_value: u16,
            att_mtu: u16,
            mutex: lib.Thread.Mutex = .{},
            cond: lib.Thread.Condition = .{},
            closed: bool = false,
            active_ops: usize = 0,
            ref_count: usize = 1,
        };

        state: *State,

        const Self = @This();

        pub fn init(
            allocator: lib.mem.Allocator,
            server: *ServerType,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            cccd_value: u16,
            att_mtu: u16,
        ) !Self {
            const state = try allocator.create(State);
            state.* = .{
                .allocator = allocator,
                .server = server,
                .conn_handle = conn_handle,
                .service_uuid = service_uuid,
                .char_uuid = char_uuid,
                .cccd_value = cccd_value,
                .att_mtu = att_mtu,
            };
            return .{ .state = state };
        }

        pub fn deinit(self: *Self) void {
            close(self.state);
            if (self.state.server.unregisterSubscription(self.state)) {
                release(self.state);
            }
            release(self.state);
        }

        pub fn write(self: *Self, data: []const u8) WriteError!void {
            if (self.canNotify()) return self.notify(data);
            return self.indicate(data);
        }

        pub fn notify(self: *Self, data: []const u8) WriteError!void {
            try beginWrite(self.state, 0x0001);
            defer endWrite(self.state);
            return self.state.server.notify(self.state.conn_handle, self.state.char_uuid, data);
        }

        pub fn indicate(self: *Self, data: []const u8) WriteError!void {
            try beginWrite(self.state, 0x0002);
            defer endWrite(self.state);
            return self.state.server.indicate(self.state.conn_handle, self.state.char_uuid, data);
        }

        pub fn connHandle(self: *const Self) u16 {
            return self.state.conn_handle;
        }

        pub fn serviceUuid(self: *const Self) u16 {
            return self.state.service_uuid;
        }

        pub fn charUuid(self: *const Self) u16 {
            return self.state.char_uuid;
        }

        pub fn cccdValue(self: *const Self) u16 {
            return self.state.cccd_value;
        }

        pub fn attMtu(self: *const Self) u16 {
            self.state.mutex.lock();
            defer self.state.mutex.unlock();
            return self.state.att_mtu;
        }

        pub fn canNotify(self: *const Self) bool {
            return (self.state.cccd_value & 0x0001) != 0;
        }

        pub fn canIndicate(self: *const Self) bool {
            return (self.state.cccd_value & 0x0002) != 0;
        }

        pub fn matches(state: *const State, conn_handle: u16, service_uuid: u16, char_uuid: u16) bool {
            return state.conn_handle == conn_handle and state.service_uuid == service_uuid and state.char_uuid == char_uuid;
        }

        pub fn matchesConn(state: *const State, conn_handle: u16) bool {
            return state.conn_handle == conn_handle;
        }

        pub fn close(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.closed = true;
            state.cond.broadcast();
        }

        pub fn retain(state: *State) void {
            state.mutex.lock();
            state.ref_count += 1;
            state.mutex.unlock();
        }

        pub fn setAttMtu(state: *State, mtu: u16) void {
            state.mutex.lock();
            state.att_mtu = mtu;
            state.mutex.unlock();
        }

        pub fn release(state: *State) void {
            state.mutex.lock();
            if (state.ref_count == 0) unreachable;
            state.ref_count -= 1;
            if (state.ref_count != 0) {
                state.mutex.unlock();
                return;
            }
            state.closed = true;
            while (state.active_ops != 0) {
                state.cond.wait(&state.mutex);
            }
            state.mutex.unlock();
            state.allocator.destroy(state);
        }

        fn beginWrite(state: *State, required_bits: u16) WriteError!void {
            state.mutex.lock();
            errdefer state.mutex.unlock();
            if (state.closed) return error.Closed;
            if ((state.cccd_value & required_bits) == 0) return error.UnsupportedMode;
            state.active_ops += 1;
            state.mutex.unlock();
        }

        fn endWrite(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.active_ops -= 1;
            if (state.active_ops == 0) {
                state.cond.broadcast();
            }
        }
    };
}

pub fn make(comptime lib: type, comptime Channel: fn (type) type) type {
    return struct {
        const Self = @This();
        pub const ChannelFactory = Channel;

        pub const OnRequestFn = *const fn (?*anyopaque, *const bt.Peripheral.Request, *bt.Peripheral.ResponseWriter) void;
        pub const OnSubscriptionFn = *const fn (?*anyopaque, Self.Subscription) void;
        pub const Handler = struct {
            onRequest: ?OnRequestFn = null,
            onSubscription: ?OnSubscriptionFn = null,
        };
        pub const Subscription = root.Subscription(lib, Self);
        pub const HandleError = error{
            DuplicateRoute,
            Unexpected,
        };
        const CharKey = struct {
            service_uuid: u16,
            char_uuid: u16,
        };
        const Route = struct {
            handler: Handler,
            ctx: ?*anyopaque,
        };
        const ConnState = struct {
            att_mtu: u16 = att.DEFAULT_MTU,
            subscriptions: lib.AutoHashMapUnmanaged(CharKey, *Self.Subscription.State) = .{},

            fn isEmpty(self: *const ConnState) bool {
                return self.subscriptions.count() == 0;
            }

            fn deinit(self: *ConnState, allocator: lib.mem.Allocator) void {
                var subs = self.subscriptions.iterator();
                while (subs.next()) |entry| {
                    const state = entry.value_ptr.*;
                    Self.Subscription.close(state);
                    Self.Subscription.release(state);
                }

                self.subscriptions.deinit(allocator);
                self.* = .{};
            }
        };

        allocator: lib.mem.Allocator,
        peripheral: ?bt.Peripheral = null,
        hook_installed: bool = false,
        mutex: lib.Thread.Mutex = .{},
        routes: lib.AutoHashMapUnmanaged(CharKey, Route) = .{},
        conns: lib.AutoHashMapUnmanaged(u16, ConnState) = .{},

        pub fn init(allocator: lib.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn bind(self: *Self, peripheral: bt.Peripheral) void {
            if (self.peripheral == null) {
                self.peripheral = peripheral;
            } else {
                std.debug.assert(samePeripheral(self.peripheral.?, peripheral));
            }

            if (!self.hook_installed) {
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
            var conn_iter = self.conns.iterator();
            while (conn_iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.conns.deinit(self.allocator);
            self.routes.deinit(self.allocator);
            self.mutex.unlock();

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

        pub fn handle(self: *Self, service_uuid: u16, char_uuid: u16, handler: Handler, ctx: ?*anyopaque) HandleError!void {
            return self.registerRoute(service_uuid, char_uuid, handler, ctx);
        }

        fn unregisterSubscription(self: *Self, state: *Self.Subscription.State) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.removeSubscriptionLocked(state);
        }

        pub fn notify(self: *Self, conn_handle: u16, char_uuid: u16, data: []const u8) bt.Peripheral.GattError!void {
            return self.peripheralPtr().notify(conn_handle, char_uuid, data);
        }

        pub fn indicate(self: *Self, conn_handle: u16, char_uuid: u16, data: []const u8) bt.Peripheral.GattError!void {
            return self.peripheralPtr().indicate(conn_handle, char_uuid, data);
        }

        fn peripheralPtr(self: *Self) bt.Peripheral {
            return self.peripheral orelse @panic("host.Server used before bind()");
        }

        fn samePeripheral(a: bt.Peripheral, b: bt.Peripheral) bool {
            return a.ptr == b.ptr and a.vtable == b.vtable;
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
                if (matched.handler.onRequest) |request_fn| {
                    request_fn(matched.ctx, req, rw);
                    return;
                }
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            }

            rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
        }

        fn onPeripheralEvent(ctx: ?*anyopaque, event: bt.Peripheral.Event) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .disconnected => |conn_handle| self.handleDisconnect(conn_handle),
                .mtu_changed => |info| self.handleMtuChanged(info),
                else => {},
            }
        }

        fn onSubscriptionChanged(ctx: ?*anyopaque, info: bt.Peripheral.SubscriptionInfo) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.handleSubscriptionChanged(info);
        }

        fn handleSubscriptionChanged(self: *Self, info: bt.Peripheral.SubscriptionInfo) void {
            self.mutex.lock();
            self.closeMatchingLocked(info.conn_handle, info.service_uuid, info.char_uuid);
            if (info.cccd_value == 0) {
                self.mutex.unlock();
                return;
            }

            const route = self.findRouteLocked(info.service_uuid, info.char_uuid) orelse {
                self.mutex.unlock();
                return;
            };
            const onSubscription = route.handler.onSubscription orelse {
                self.mutex.unlock();
                return;
            };

            const conn = self.getOrPutConnLocked(info.conn_handle) catch {
                self.mutex.unlock();
                return;
            };
            const sub = Self.Subscription.init(
                self.allocator,
                self,
                info.conn_handle,
                info.service_uuid,
                info.char_uuid,
                info.cccd_value,
                conn.att_mtu,
            ) catch {
                self.mutex.unlock();
                return;
            };
            conn.subscriptions.put(self.allocator, charKey(info.service_uuid, info.char_uuid), sub.state) catch {
                self.mutex.unlock();
                Self.Subscription.release(sub.state);
                return;
            };
            Self.Subscription.retain(sub.state);
            const ctx = route.ctx;
            self.mutex.unlock();

            onSubscription(ctx, sub);
        }

        fn handleDisconnect(self: *Self, conn_handle: u16) void {
            self.mutex.lock();
            if (self.takeConnLocked(conn_handle)) |conn_state| {
                var conn = conn_state;
                conn.deinit(self.allocator);
            }
            self.mutex.unlock();
        }

        fn handleMtuChanged(self: *Self, info: bt.Peripheral.MtuInfo) void {
            self.mutex.lock();
            const conn = self.getOrPutConnLocked(info.conn_handle) catch {
                self.mutex.unlock();
                return;
            };
            conn.att_mtu = info.mtu;
            var subs = conn.subscriptions.iterator();
            while (subs.next()) |entry| {
                Self.Subscription.setAttMtu(entry.value_ptr.*, info.mtu);
            }
            self.mutex.unlock();
        }

        fn closeMatchingLocked(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) void {
            const conn = self.conns.getPtr(conn_handle) orelse return;
            const key = charKey(service_uuid, char_uuid);

            if (conn.subscriptions.get(key)) |state| {
                _ = conn.subscriptions.remove(key);
                Self.Subscription.close(state);
                Self.Subscription.release(state);
            }
        }

        fn removeSubscriptionLocked(self: *Self, state: *Self.Subscription.State) bool {
            const conn = self.conns.getPtr(state.conn_handle) orelse return false;
            const key = charKey(state.service_uuid, state.char_uuid);
            const existing = conn.subscriptions.get(key) orelse return false;
            if (existing != state) {
                return false;
            }
            _ = conn.subscriptions.remove(key);
            return true;
        }

        fn registerRoute(
            self: *Self,
            service_uuid: u16,
            char_uuid: u16,
            handler: Handler,
            ctx: ?*anyopaque,
        ) HandleError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.routes.contains(charKey(service_uuid, char_uuid))) {
                return error.DuplicateRoute;
            }
            self.routes.put(self.allocator, charKey(service_uuid, char_uuid), .{
                .handler = handler,
                .ctx = ctx,
            }) catch return error.Unexpected;
        }

        fn findRouteLocked(self: *Self, service_uuid: u16, char_uuid: u16) ?Route {
            return self.routes.get(charKey(service_uuid, char_uuid));
        }
    };
}

