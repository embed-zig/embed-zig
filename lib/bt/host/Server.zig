//! host.Server — higher-level server facade built on host.Peripheral.

const std = @import("std");
const bt = @import("../../bt.zig");
const att = @import("att.zig");
const SubscriptionMod = @import("server/Subscription.zig");
const xfer_chunk = @import("client/xfer/chunk.zig");

pub fn Server(comptime lib: type, comptime Channel: fn (type) type, comptime PeripheralType: type) type {
    return struct {
        const Self = @This();

        pub const Request = bt.Peripheral.Request;
        pub const ResponseWriter = bt.Peripheral.ResponseWriter;
        pub const ReadXRequest = @import("server/xfer/ReadXRequest.zig");
        pub const WriteXRequest = @import("server/xfer/WriteXRequest.zig");
        pub const ReadXResponseWriter = @import("server/xfer/ReadXResponseWriter.zig");
        pub const HandlerFn = *const fn (?*anyopaque, *const Request, *ResponseWriter) void;
        pub const ReadXHandlerFn = *const fn (?*anyopaque, *const ReadXRequest, *ReadXResponseWriter) void;
        pub const WriteXHandlerFn = *const fn (?*anyopaque, *const WriteXRequest) void;
        pub const XHandler = struct {
            read: ?ReadXHandlerFn = null,
            write: ?WriteXHandlerFn = null,
        };
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
        const XferRoute = struct {
            callbacks: XHandler,
            ctx: ?*anyopaque,
        };
        const RouteKind = union(enum) {
            plain: PlainRoute,
            xfer: XferRoute,
        };
        const Route = struct {
            kind: RouteKind,
        };

        const BufferedResponseState = struct {
            allocator: lib.mem.Allocator,
            buf: std.ArrayListUnmanaged(u8) = .{},
            err_code: ?u8 = null,

            fn deinit(self: *BufferedResponseState) void {
                self.buf.deinit(self.allocator);
            }

            fn writer(self: *BufferedResponseState) ReadXResponseWriter {
                return .{
                    ._impl = self,
                    ._write_fn = writeFn,
                    ._err_fn = errFn,
                };
            }

            fn takeOwned(self: *BufferedResponseState) ![]u8 {
                const out = try self.allocator.alloc(u8, self.buf.items.len);
                @memcpy(out, self.buf.items);
                self.buf.deinit(self.allocator);
                self.buf = .{};
                return out;
            }

            fn writeFn(ptr: *anyopaque, data: []const u8) void {
                const self: *BufferedResponseState = @ptrCast(@alignCast(ptr));
                self.buf.appendSlice(self.allocator, data) catch {
                    if (self.err_code == null) {
                        self.err_code = @intFromEnum(att.ErrorCode.insufficient_resources);
                    }
                };
            }

            fn errFn(ptr: *anyopaque, code: u8) void {
                const self: *BufferedResponseState = @ptrCast(@alignCast(ptr));
                self.err_code = code;
            }
        };

        const ReadXState = struct {
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            mode: PushMode,
            data: []u8,
            total: u16,
            dcs: usize,
        };

        const WriteXState = struct {
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            mode: PushMode,
            total: u16 = 0,
            dcs: usize = xfer_chunk.dataChunkSize(default_xfer_mtu),
            last_chunk_len: usize = 0,
            initialized: bool = false,
            recv_buf: ?[]u8 = null,
            rcvmask: [xfer_chunk.max_mask_bytes]u8 = [_]u8{0} ** xfer_chunk.max_mask_bytes,

            fn deinit(self: *WriteXState, allocator: lib.mem.Allocator) void {
                if (self.recv_buf) |buf| allocator.free(buf);
                self.recv_buf = null;
            }
        };
        const ConnState = struct {
            subscriptions: lib.AutoHashMapUnmanaged(CharKey, *SubscriptionState) = .{},
            read_x_states: lib.AutoHashMapUnmanaged(CharKey, ReadXState) = .{},
            write_x_states: lib.AutoHashMapUnmanaged(CharKey, WriteXState) = .{},

            fn isEmpty(self: *const ConnState) bool {
                return self.subscriptions.count() == 0 and
                    self.read_x_states.count() == 0 and
                    self.write_x_states.count() == 0;
            }

            fn deinit(self: *ConnState, allocator: lib.mem.Allocator) void {
                var subs = self.subscriptions.iterator();
                while (subs.next()) |entry| {
                    const state = entry.value_ptr.*;
                    Subscription.close(state);
                    if (state.internal) {
                        Subscription.destroyState(state);
                    }
                }

                var read_iter = self.read_x_states.iterator();
                while (read_iter.next()) |entry| {
                    allocator.free(entry.value_ptr.data);
                }

                var write_iter = self.write_x_states.iterator();
                while (write_iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                }

                self.subscriptions.deinit(allocator);
                self.read_x_states.deinit(allocator);
                self.write_x_states.deinit(allocator);
                self.* = .{};
            }
        };

        const default_xfer_mtu: u16 = 247;

        allocator: lib.mem.Allocator,
        peripheral: ?*PeripheralType = null,
        hook_installed: bool = false,
        mutex: lib.Thread.Mutex = .{},
        cond: lib.Thread.Condition = .{},
        routes: lib.AutoHashMapUnmanaged(CharKey, Route) = .{},
        conns: lib.AutoHashMapUnmanaged(u16, ConnState) = .{},
        accept_ch: AcceptCh,
        queued_count: usize = 0,
        enqueue_inflight: usize = 0,
        closed: bool = false,

        pub fn init(allocator: lib.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
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
                Subscription.destroyState(recv_res.value);
            }
            self.accept_ch.deinit();

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
                    Subscription.destroyState(state);
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
                    .xfer => |xfer| self.dispatchXferRequest(xfer, req, rw),
                }
                return;
            }

            rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
        }

        fn onPeripheralEvent(ctx: ?*anyopaque, event: bt.Peripheral.PeripheralEvent) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .disconnected => |conn_handle| self.handleDisconnect(conn_handle),
                else => {},
            }
        }

        fn onSubscriptionChanged(ctx: ?*anyopaque, info: PeripheralType.SubscriptionInfo) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.handleSubscriptionChanged(info);
        }

        fn handleSubscriptionChanged(self: *Self, info: PeripheralType.SubscriptionInfo) void {
            self.mutex.lock();
            self.closeMatchingLocked(info.conn_handle, info.service_uuid, info.char_uuid);
            if (self.closed or info.cccd_value == 0) {
                self.mutex.unlock();
                return;
            }

            const internal = if (self.findRouteLocked(info.service_uuid, info.char_uuid)) |route|
                switch (route.kind) {
                    .plain => false,
                    .xfer => true,
                }
            else
                false;

            const sub = Subscription.init(
                self.allocator,
                self,
                info.conn_handle,
                info.service_uuid,
                info.char_uuid,
                info.cccd_value,
                internal,
            ) catch {
                self.mutex.unlock();
                return;
            };

            const conn = self.getOrPutConnLocked(info.conn_handle) catch {
                self.mutex.unlock();
                Subscription.destroyState(sub.state);
                return;
            };
            conn.subscriptions.put(self.allocator, charKey(info.service_uuid, info.char_uuid), sub.state) catch {
                self.mutex.unlock();
                Subscription.destroyState(sub.state);
                return;
            };
            if (internal) {
                self.mutex.unlock();
                return;
            }
            self.enqueue_inflight += 1;
            self.mutex.unlock();

            const send_res = self.accept_ch.send(sub.state) catch {
                self.mutex.lock();
                self.enqueue_inflight -= 1;
                self.cond.broadcast();
                _ = self.removeSubscriptionLocked(sub.state);
                self.mutex.unlock();
                Subscription.destroyState(sub.state);
                return;
            };

            self.mutex.lock();
            self.enqueue_inflight -= 1;
            self.cond.broadcast();
            if (!self.closed and send_res.ok) {
                self.queued_count += 1;
                self.cond.signal();
            } else {
                _ = self.removeSubscriptionLocked(sub.state);
                self.mutex.unlock();
                Subscription.destroyState(sub.state);
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
                if (state.internal) {
                    Subscription.destroyState(state);
                }
            }
            self.clearReadXStateInConnLocked(conn, key);
            self.clearWriteXStateInConnLocked(conn, key);
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
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.upsertRouteLocked(service_uuid, char_uuid, .{
                .xfer = .{
                    .callbacks = handler,
                    .ctx = ctx,
                },
            });
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

        fn dispatchXferRequest(self: *Self, route: XferRoute, req: *const Request, rw: *ResponseWriter) void {
            switch (req.op) {
                .write, .write_without_response => {},
                .read => {
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                },
            }

            if (xfer_chunk.isReadStartMagic(req.data)) {
                self.handleXReadStart(route, req, rw);
                return;
            }
            if (xfer_chunk.isWriteStartMagic(req.data)) {
                self.handleXWriteStart(route, req, rw);
                return;
            }
            if (self.handleXWriteChunk(route, req, rw)) return;
            if (xfer_chunk.isAck(req.data)) {
                self.handleXReadAck(req, rw);
                return;
            }
            if (self.handleXReadLossList(req, rw)) return;

            rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
        }

        fn handleXReadStart(self: *Self, route: XferRoute, req: *const Request, rw: *ResponseWriter) void {
            const read_handler = route.callbacks.read orelse {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };
            const mode = self.subscriptionMode(req.conn_handle, req.service_uuid, req.char_uuid) orelse {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };

            var buffered = BufferedResponseState{ .allocator = self.allocator };
            defer buffered.deinit();

            var handler_rw = buffered.writer();
            const handler_req: ReadXRequest = .{
                .conn_handle = req.conn_handle,
                .service_uuid = req.service_uuid,
                .char_uuid = req.char_uuid,
            };
            read_handler(route.ctx, &handler_req, &handler_rw);

            if (buffered.err_code) |code| {
                rw.err(code);
                return;
            }

            const payload = buffered.takeOwned() catch {
                rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                return;
            };

            const dcs = xfer_chunk.dataChunkSize(default_xfer_mtu);
            const total_usize = if (payload.len == 0) 1 else xfer_chunk.chunksNeeded(payload.len, default_xfer_mtu);
            if (total_usize > xfer_chunk.max_chunks) {
                self.allocator.free(payload);
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return;
            }

            self.mutex.lock();
            self.clearReadXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
            self.clearWriteXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
            const conn = self.conns.getPtr(req.conn_handle) orelse {
                self.mutex.unlock();
                self.allocator.free(payload);
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };
            conn.read_x_states.put(self.allocator, charKey(req.service_uuid, req.char_uuid), .{
                .conn_handle = req.conn_handle,
                .service_uuid = req.service_uuid,
                .char_uuid = req.char_uuid,
                .mode = mode,
                .data = payload,
                .total = @intCast(total_usize),
                .dcs = dcs,
            }) catch {
                self.mutex.unlock();
                self.allocator.free(payload);
                rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                return;
            };
            self.mutex.unlock();

            rw.ok();
            self.sendReadXChunks(req.conn_handle, req.service_uuid, req.char_uuid, null) catch {
                self.mutex.lock();
                self.clearReadXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
                self.mutex.unlock();
            };
        }

        fn handleXWriteStart(self: *Self, route: XferRoute, req: *const Request, rw: *ResponseWriter) void {
            if (route.callbacks.write == null) {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            }
            const mode = self.subscriptionMode(req.conn_handle, req.service_uuid, req.char_uuid) orelse {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };

            self.mutex.lock();
            self.clearReadXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
            self.clearWriteXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
            const conn = self.conns.getPtr(req.conn_handle) orelse {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };
            conn.write_x_states.put(self.allocator, charKey(req.service_uuid, req.char_uuid), .{
                .conn_handle = req.conn_handle,
                .service_uuid = req.service_uuid,
                .char_uuid = req.char_uuid,
                .mode = mode,
            }) catch {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                return;
            };
            self.mutex.unlock();
            rw.ok();
        }

        fn handleXWriteChunk(self: *Self, route: XferRoute, req: *const Request, rw: *ResponseWriter) bool {
            self.mutex.lock();
            const conn = self.conns.getPtr(req.conn_handle) orelse {
                self.mutex.unlock();
                return false;
            };
            const state = conn.write_x_states.getPtr(charKey(req.service_uuid, req.char_uuid)) orelse {
                self.mutex.unlock();
                return false;
            };

            if (req.data.len < xfer_chunk.header_size) {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return true;
            }

            const hdr = xfer_chunk.Header.decode(req.data[0..xfer_chunk.header_size]);
            hdr.validate() catch {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return true;
            };

            if (!state.initialized) {
                state.total = hdr.total;
                xfer_chunk.Bitmask.initClear(state.rcvmask[0..xfer_chunk.Bitmask.requiredBytes(hdr.total)], hdr.total);
                state.recv_buf = self.allocator.alloc(u8, @as(usize, hdr.total) * state.dcs) catch {
                    self.mutex.unlock();
                    rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                    return true;
                };
                state.initialized = true;
            } else if (state.total != hdr.total) {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return true;
            }

            const payload_len = req.data.len - xfer_chunk.header_size;
            const write_at = (@as(usize, hdr.seq) - 1) * state.dcs;
            const buf = state.recv_buf orelse unreachable;
            if (payload_len > state.dcs or write_at + payload_len > buf.len) {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return true;
            }
            @memcpy(buf[write_at .. write_at + payload_len], req.data[xfer_chunk.header_size..]);
            if (hdr.seq == state.total) {
                state.last_chunk_len = payload_len;
            }

            const mask_len = xfer_chunk.Bitmask.requiredBytes(state.total);
            xfer_chunk.Bitmask.set(state.rcvmask[0..mask_len], hdr.seq);
            const complete = xfer_chunk.Bitmask.isComplete(state.rcvmask[0..mask_len], state.total);
            const should_reply = complete or hdr.seq == state.total;

            const conn_handle = state.conn_handle;
            const service_uuid = state.service_uuid;
            const char_uuid = state.char_uuid;
            const mode = state.mode;
            const data_len = if (complete)
                (@as(usize, state.total) - 1) * state.dcs + state.last_chunk_len
            else
                0;
            const data: []const u8 = if (complete)
                (state.recv_buf orelse unreachable)[0..data_len]
            else
                &.{};
            self.mutex.unlock();

            rw.ok();
            if (!should_reply) return true;

            if (complete) {
                invokeXferWriteHandler(route, conn_handle, service_uuid, char_uuid, data);
                self.push(conn_handle, char_uuid, mode, &xfer_chunk.ack_signal) catch {};
                self.mutex.lock();
                self.clearWriteXStateLocked(conn_handle, service_uuid, char_uuid);
                self.mutex.unlock();
                return true;
            }

            self.sendWriteXLossList(conn_handle, service_uuid, char_uuid, mode) catch {
                self.mutex.lock();
                self.clearWriteXStateLocked(conn_handle, service_uuid, char_uuid);
                self.mutex.unlock();
            };
            return true;
        }

        fn handleXReadAck(self: *Self, req: *const Request, rw: *ResponseWriter) void {
            self.mutex.lock();
            self.clearReadXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
            self.mutex.unlock();
            rw.ok();
        }

        fn handleXReadLossList(self: *Self, req: *const Request, rw: *ResponseWriter) bool {
            if ((req.data.len % 2) != 0 or req.data.len == 0) return false;

            self.mutex.lock();
            const exists = if (self.conns.getPtr(req.conn_handle)) |conn|
                conn.read_x_states.get(charKey(req.service_uuid, req.char_uuid)) != null
            else
                false;
            self.mutex.unlock();
            if (!exists) return false;

            rw.ok();
            self.sendReadXChunks(req.conn_handle, req.service_uuid, req.char_uuid, req.data) catch {
                self.mutex.lock();
                self.clearReadXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
                self.mutex.unlock();
            };
            return true;
        }

        fn invokeXferWriteHandler(
            route: XferRoute,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            data: []const u8,
        ) void {
            const write_handler = route.callbacks.write orelse return;
            const handler_req: WriteXRequest = .{
                .conn_handle = conn_handle,
                .service_uuid = service_uuid,
                .char_uuid = char_uuid,
                .data = data,
            };
            write_handler(route.ctx, &handler_req);
        }

        fn sendReadXChunks(
            self: *Self,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            loss_list: ?[]const u8,
        ) PushError!void {
            self.mutex.lock();
            const conn = self.conns.getPtr(conn_handle) orelse {
                self.mutex.unlock();
                return;
            };
            const state = conn.read_x_states.get(charKey(service_uuid, char_uuid)) orelse {
                self.mutex.unlock();
                return;
            };
            self.mutex.unlock();

            var selected: [260]u16 = undefined;
            const seqs: []const u16 = if (loss_list) |list|
                selected[0..xfer_chunk.decodeLossList(list, &selected)]
            else
                &.{};

            var chunk_buf: [xfer_chunk.max_mtu]u8 = undefined;
            if (loss_list != null) {
                for (seqs) |seq| {
                    try self.sendReadXChunk(state, seq, &chunk_buf);
                }
                return;
            }

            var seq: u16 = 1;
            while (seq <= state.total) : (seq += 1) {
                try self.sendReadXChunk(state, seq, &chunk_buf);
            }
        }

        fn sendReadXChunk(self: *Self, state: ReadXState, seq: u16, chunk_buf: []u8) PushError!void {
            if (seq == 0 or seq > state.total) return;

            const hdr = (xfer_chunk.Header{ .total = state.total, .seq = seq }).encode();
            @memcpy(chunk_buf[0..xfer_chunk.header_size], &hdr);

            const offset = (@as(usize, seq) - 1) * state.dcs;
            const payload_len = if (state.data.len == 0)
                0
            else
                @min(state.data.len -| offset, state.dcs);
            if (payload_len > 0) {
                @memcpy(
                    chunk_buf[xfer_chunk.header_size .. xfer_chunk.header_size + payload_len],
                    state.data[offset .. offset + payload_len],
                );
            }

            try self.push(
                state.conn_handle,
                state.char_uuid,
                state.mode,
                chunk_buf[0 .. xfer_chunk.header_size + payload_len],
            );
        }

        fn sendWriteXLossList(
            self: *Self,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            mode: PushMode,
        ) PushError!void {
            self.mutex.lock();
            const conn = self.conns.getPtr(conn_handle) orelse {
                self.mutex.unlock();
                return;
            };
            const state = conn.write_x_states.get(charKey(service_uuid, char_uuid)) orelse {
                self.mutex.unlock();
                return;
            };
            self.mutex.unlock();

            var missing: [260]u16 = undefined;
            const count = xfer_chunk.Bitmask.collectMissing(
                state.rcvmask[0..xfer_chunk.Bitmask.requiredBytes(state.total)],
                state.total,
                &missing,
            );
            if (count == 0) return;

            var buf: [xfer_chunk.max_mtu]u8 = undefined;
            const encoded = xfer_chunk.encodeLossList(missing[0..count], &buf);
            try self.push(conn_handle, char_uuid, mode, encoded);
        }

        fn subscriptionMode(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) ?PushMode {
            self.mutex.lock();
            defer self.mutex.unlock();

            const conn = self.conns.getPtr(conn_handle) orelse return null;
            const state = conn.subscriptions.get(charKey(service_uuid, char_uuid)) orelse return null;
            if ((state.cccd_value & 0x0001) != 0) return .notify;
            if ((state.cccd_value & 0x0002) != 0) return .indicate;
            return null;
        }

        fn clearReadXStateInConnLocked(self: *Self, conn: *ConnState, key: CharKey) void {
            const state = conn.read_x_states.get(key) orelse return;
            _ = conn.read_x_states.remove(key);
            self.allocator.free(state.data);
        }

        fn clearReadXStateLocked(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) void {
            const conn = self.conns.getPtr(conn_handle) orelse return;
            self.clearReadXStateInConnLocked(conn, charKey(service_uuid, char_uuid));
            self.pruneConnIfEmptyLocked(conn_handle);
        }

        fn clearWriteXStateInConnLocked(self: *Self, conn: *ConnState, key: CharKey) void {
            const state = conn.write_x_states.get(key) orelse return;
            _ = conn.write_x_states.remove(key);
            var owned = state;
            owned.deinit(self.allocator);
        }

        fn clearWriteXStateLocked(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) void {
            const conn = self.conns.getPtr(conn_handle) orelse return;
            self.clearWriteXStateInConnLocked(conn, charKey(service_uuid, char_uuid));
            self.pruneConnIfEmptyLocked(conn_handle);
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
