//! Server — server-side xfer engine.

const bt = @import("../../../bt.zig");
const att = @import("../att.zig");
const Chunk = @import("Chunk.zig");

pub fn Server(comptime lib: type, comptime HostServerType: type) type {
    return struct {
        const Self = @This();

        pub const ReadXRequest = @import("ReadXRequest.zig");
        pub const WriteXRequest = @import("WriteXRequest.zig");
        pub const ReadXResponseWriter = @import("ReadXResponseWriter.zig");
        pub const ReadXHandlerFn = *const fn (?*anyopaque, *const ReadXRequest, *ReadXResponseWriter) void;
        pub const WriteXHandlerFn = *const fn (?*anyopaque, *const WriteXRequest) void;
        pub const XHandler = struct {
            read: ?ReadXHandlerFn = null,
            write: ?WriteXHandlerFn = null,
        };
        pub const HandleError = error{Unexpected};

        pub const default_write_idle_timeout_ms: u32 = 1000;
        const max_idle_retries: u8 = 5;

        const Request = bt.Peripheral.Request;
        const ResponseWriter = bt.Peripheral.ResponseWriter;
        const PushMode = HostServerType.PushMode;
        const CharKey = struct {
            service_uuid: u16,
            char_uuid: u16,
        };
        const Route = struct {
            callbacks: XHandler,
            ctx: ?*anyopaque,
        };
        const BufferedResponseState = struct {
            allocator: lib.mem.Allocator,
            buf: lib.ArrayListUnmanaged(u8) = .{},
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
            topic: ?Chunk.Topic = null,
            request_metadata: []u8,
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
            dcs: usize = Chunk.dataChunkSize(att.DEFAULT_MTU),
            last_chunk_len: usize = 0,
            initialized: bool = false,
            recv_buf: ?[]u8 = null,
            rcvmask: [Chunk.max_mask_bytes]u8 = [_]u8{0} ** Chunk.max_mask_bytes,
            last_recv_ts: i64 = 0,
            watchdog_active: bool = false,

            fn deinit(self: *WriteXState, allocator: lib.mem.Allocator) void {
                if (self.recv_buf) |buf| allocator.free(buf);
                self.recv_buf = null;
            }
        };
        const ConnState = struct {
            att_mtu: u16 = att.DEFAULT_MTU,
            push_modes: lib.AutoHashMapUnmanaged(CharKey, PushMode) = .{},
            read_x_states: lib.AutoHashMapUnmanaged(CharKey, ReadXState) = .{},
            write_x_states: lib.AutoHashMapUnmanaged(CharKey, WriteXState) = .{},

            fn isEmpty(self: *const ConnState) bool {
                return self.att_mtu == att.DEFAULT_MTU and
                    self.push_modes.count() == 0 and
                    self.read_x_states.count() == 0 and
                    self.write_x_states.count() == 0;
            }

            fn deinit(self: *ConnState, allocator: lib.mem.Allocator) void {
                var read_iter = self.read_x_states.iterator();
                while (read_iter.next()) |entry| {
                    allocator.free(entry.value_ptr.request_metadata);
                    allocator.free(entry.value_ptr.data);
                }

                var write_iter = self.write_x_states.iterator();
                while (write_iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                }

                self.push_modes.deinit(allocator);
                self.read_x_states.deinit(allocator);
                self.write_x_states.deinit(allocator);
                self.* = .{};
            }
        };

        allocator: lib.mem.Allocator,
        owner: ?*HostServerType = null,
        mutex: lib.Thread.Mutex = .{},
        routes: lib.AutoHashMapUnmanaged(CharKey, Route) = .{},
        conns: lib.AutoHashMapUnmanaged(u16, ConnState) = .{},
        closing: bool = false,
        idle_watchdog_count: u32 = 0,
        idle_watchdog_cond: lib.Thread.Condition = .{},
        write_idle_timeout_ms: u32 = default_write_idle_timeout_ms,

        pub fn init(allocator: lib.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn bind(self: *Self, owner: *HostServerType) void {
            if (self.owner == null) {
                self.owner = owner;
            } else {
                lib.debug.assert(self.owner.? == owner);
            }
        }

        pub fn setWriteIdleTimeout(self: *Self, timeout_ms: u32) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.write_idle_timeout_ms = timeout_ms;
        }

        pub fn getWriteIdleTimeout(self: *Self) u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.write_idle_timeout_ms;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            self.closing = true;
            self.idle_watchdog_cond.broadcast();
            while (self.idle_watchdog_count > 0) {
                self.idle_watchdog_cond.timedWait(&self.mutex, @as(u64, 2000) * lib.time.ns_per_ms) catch {};
            }

            var conn_iter = self.conns.iterator();
            while (conn_iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.conns.deinit(self.allocator);
            self.routes.deinit(self.allocator);
            self.owner = null;
            self.mutex.unlock();
        }

        pub fn handle(self: *Self, service_uuid: u16, char_uuid: u16, handler: XHandler, ctx: ?*anyopaque) HandleError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.routes.put(self.allocator, charKey(service_uuid, char_uuid), .{
                .callbacks = handler,
                .ctx = ctx,
            }) catch return error.Unexpected;
        }

        pub fn removeRoute(self: *Self, service_uuid: u16, char_uuid: u16) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            _ = self.routes.remove(charKey(service_uuid, char_uuid));

            var conn_iter = self.conns.iterator();
            while (conn_iter.next()) |entry| {
                self.closeMatchingInConnLocked(entry.value_ptr, charKey(service_uuid, char_uuid));
            }

            var stale: [32]u16 = undefined;
            var stale_len: usize = 0;
            var second_iter = self.conns.iterator();
            while (second_iter.next()) |entry| {
                if (entry.value_ptr.isEmpty()) {
                    if (stale_len < stale.len) {
                        stale[stale_len] = entry.key_ptr.*;
                        stale_len += 1;
                    }
                }
            }
            for (stale[0..stale_len]) |conn_handle| {
                _ = self.conns.remove(conn_handle);
            }
        }

        pub fn hasRoute(self: *Self, service_uuid: u16, char_uuid: u16) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.routes.contains(charKey(service_uuid, char_uuid));
        }

        pub fn dispatchRequest(self: *Self, req: *const Request, rw: *ResponseWriter) bool {
            self.mutex.lock();
            const route = self.routes.get(charKey(req.service_uuid, req.char_uuid));
            self.mutex.unlock();

            if (route) |matched| {
                self.dispatchXferRequest(matched, req, rw);
                return true;
            }
            return false;
        }

        pub fn handleSubscriptionChanged(self: *Self, info: bt.Peripheral.SubscriptionInfo) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closeMatchingLocked(info.conn_handle, info.service_uuid, info.char_uuid);
            if (info.cccd_value == 0) return;
            if (!self.routes.contains(charKey(info.service_uuid, info.char_uuid))) return;

            const mode = cccdPushMode(info.cccd_value) orelse return;
            const conn = self.getOrPutConnLocked(info.conn_handle) catch return;
            conn.push_modes.put(self.allocator, charKey(info.service_uuid, info.char_uuid), mode) catch return;
        }

        pub fn handleDisconnect(self: *Self, conn_handle: u16) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.takeConnLocked(conn_handle)) |conn_state| {
                var conn = conn_state;
                conn.deinit(self.allocator);
                self.idle_watchdog_cond.broadcast();
            }
        }

        pub fn handleMtuChanged(self: *Self, conn_handle: u16, mtu: u16) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const conn = self.getOrPutConnLocked(conn_handle) catch return;
            resetXferStatesInConn(conn, self.allocator);
            conn.att_mtu = effectiveMtu(mtu);
            self.idle_watchdog_cond.broadcast();
        }

        fn ownerPtr(self: *Self) *HostServerType {
            return self.owner orelse @panic("xfer.Server used before host.Server binding");
        }

        fn charKey(service_uuid: u16, char_uuid: u16) CharKey {
            return .{
                .service_uuid = service_uuid,
                .char_uuid = char_uuid,
            };
        }

        fn cccdPushMode(cccd_value: u16) ?PushMode {
            if ((cccd_value & 0x0001) != 0) return .notify;
            if ((cccd_value & 0x0002) != 0) return .indicate;
            return null;
        }

        fn effectiveMtu(mtu: u16) u16 {
            return @max(att.DEFAULT_MTU, @min(mtu, att.MAX_MTU));
        }

        fn readStartMatchesState(state: ReadXState, request_meta: Chunk.ReadStartMetadata) bool {
            return state.topic == request_meta.topic and lib.mem.eql(u8, state.request_metadata, request_meta.metadata);
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

        fn pruneConnIfEmptyLocked(self: *Self, conn_handle: u16) void {
            const conn = self.conns.getPtr(conn_handle) orelse return;
            if (conn.isEmpty()) {
                _ = self.conns.remove(conn_handle);
            }
        }

        fn closeMatchingLocked(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) void {
            const conn = self.conns.getPtr(conn_handle) orelse return;
            self.closeMatchingInConnLocked(conn, charKey(service_uuid, char_uuid));
            self.pruneConnIfEmptyLocked(conn_handle);
        }

        fn closeMatchingInConnLocked(self: *Self, conn: *ConnState, key: CharKey) void {
            _ = conn.push_modes.remove(key);
            self.clearReadXStateInConnLocked(conn, key);
            self.clearWriteXStateInConnLocked(conn, key);
        }

        fn dispatchXferRequest(self: *Self, route: Route, req: *const Request, rw: *ResponseWriter) void {
            switch (req.op) {
                .write, .write_without_response => {},
                .read => {
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                },
            }

            if (Chunk.isReadStartMagic(req.data)) {
                self.handleXReadStart(route, req, rw);
                return;
            }
            if (Chunk.isWriteStartMagic(req.data)) {
                self.handleXWriteStart(route, req, rw);
                return;
            }
            if (self.handleXWriteChunk(route, req, rw)) return;
            if (Chunk.isAck(req.data)) {
                self.handleXReadAck(req, rw);
                return;
            }
            if (self.handleXReadLossList(req, rw)) return;

            rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
        }

        fn handleXReadStart(self: *Self, route: Route, req: *const Request, rw: *ResponseWriter) void {
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

            const request_meta = Chunk.decodeReadStartMetadata(req.data[Chunk.read_start_magic.len..]) catch {
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return;
            };

            self.mutex.lock();
            const existing_read = blk: {
                const conn = self.conns.getPtr(req.conn_handle) orelse break :blk null;
                break :blk conn.read_x_states.get(charKey(req.service_uuid, req.char_uuid));
            };
            self.mutex.unlock();
            if (existing_read) |state| {
                if (!readStartMatchesState(state, request_meta)) {
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                }
                rw.ok();
                self.sendReadXChunks(req.conn_handle, req.service_uuid, req.char_uuid, null) catch {};
                return;
            }

            var handler_rw = buffered.writer();
            const handler_req: ReadXRequest = .{
                .conn_handle = req.conn_handle,
                .service_uuid = req.service_uuid,
                .char_uuid = req.char_uuid,
                .topic = request_meta.topic,
                .metadata = request_meta.metadata,
            };
            read_handler(route.ctx, &handler_req, &handler_rw);

            if (buffered.err_code) |code| {
                rw.err(code);
                return;
            }

            const owned_request_metadata = self.allocator.dupe(u8, request_meta.metadata) catch {
                rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                return;
            };
            const payload = buffered.takeOwned() catch {
                self.allocator.free(owned_request_metadata);
                rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                return;
            };

            self.mutex.lock();
            self.clearWriteXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
            const conn = self.conns.getPtr(req.conn_handle) orelse {
                self.mutex.unlock();
                self.allocator.free(owned_request_metadata);
                self.allocator.free(payload);
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };
            if (conn.read_x_states.get(charKey(req.service_uuid, req.char_uuid))) |state| {
                const same_request = readStartMatchesState(state, request_meta);
                self.mutex.unlock();
                self.allocator.free(owned_request_metadata);
                self.allocator.free(payload);
                if (!same_request) {
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                }
                rw.ok();
                self.sendReadXChunks(req.conn_handle, req.service_uuid, req.char_uuid, null) catch {};
                return;
            }
            const mtu = effectiveMtu(conn.att_mtu);
            const dcs = Chunk.dataChunkSize(mtu);
            const total_usize = if (payload.len == 0) 1 else Chunk.chunksNeeded(payload.len, mtu);
            if (total_usize > Chunk.max_chunks) {
                self.mutex.unlock();
                self.allocator.free(owned_request_metadata);
                self.allocator.free(payload);
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return;
            }
            conn.read_x_states.put(self.allocator, charKey(req.service_uuid, req.char_uuid), .{
                .conn_handle = req.conn_handle,
                .service_uuid = req.service_uuid,
                .char_uuid = req.char_uuid,
                .mode = mode,
                .topic = request_meta.topic,
                .request_metadata = owned_request_metadata,
                .data = payload,
                .total = @intCast(total_usize),
                .dcs = dcs,
            }) catch {
                self.mutex.unlock();
                self.allocator.free(owned_request_metadata);
                self.allocator.free(payload);
                rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                return;
            };
            self.mutex.unlock();

            rw.ok();
            self.sendReadXChunks(req.conn_handle, req.service_uuid, req.char_uuid, null) catch {
                return;
            };
        }

        fn handleXWriteStart(self: *Self, route: Route, req: *const Request, rw: *ResponseWriter) void {
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
                .dcs = Chunk.dataChunkSize(effectiveMtu(conn.att_mtu)),
            }) catch {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                return;
            };
            self.mutex.unlock();
            rw.ok();
        }

        fn handleXWriteChunk(self: *Self, route: Route, req: *const Request, rw: *ResponseWriter) bool {
            self.mutex.lock();
            const conn = self.conns.getPtr(req.conn_handle) orelse {
                self.mutex.unlock();
                return false;
            };
            const state = conn.write_x_states.getPtr(charKey(req.service_uuid, req.char_uuid)) orelse {
                self.mutex.unlock();
                return false;
            };

            if (req.data.len < Chunk.header_size) {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return true;
            }

            const hdr = Chunk.Header.decode(req.data[0..Chunk.header_size]);
            hdr.validate() catch {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return true;
            };

            if (!state.initialized) {
                state.total = hdr.total;
                Chunk.Bitmask.initClear(state.rcvmask[0..Chunk.Bitmask.requiredBytes(hdr.total)], hdr.total);
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

            const payload_len = req.data.len - Chunk.header_size;
            const write_at = (@as(usize, hdr.seq) - 1) * state.dcs;
            const buf = state.recv_buf orelse unreachable;
            if (payload_len > state.dcs or write_at + payload_len > buf.len) {
                self.mutex.unlock();
                rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                return true;
            }
            @memcpy(buf[write_at .. write_at + payload_len], req.data[Chunk.header_size..]);
            if (hdr.seq == state.total) {
                state.last_chunk_len = payload_len;
            }

            state.last_recv_ts = lib.time.milliTimestamp();

            const mask_len = Chunk.Bitmask.requiredBytes(state.total);
            Chunk.Bitmask.set(state.rcvmask[0..mask_len], hdr.seq);
            const complete = Chunk.Bitmask.isComplete(state.rcvmask[0..mask_len], state.total);
            const should_reply = complete or hdr.seq == state.total;

            const should_start_watchdog = !should_reply and state.initialized and !state.watchdog_active;
            if (should_start_watchdog) {
                state.watchdog_active = true;
                self.idle_watchdog_count += 1;
            }

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

            if (should_start_watchdog) {
                self.startIdleWatchdog(conn_handle, service_uuid, char_uuid);
            }

            if (!should_reply) return true;

            if (complete) {
                // Queue the ACK before invoking the application callback so an
                // ACK transport failure does not commit a side effect the client
                // will likely retry.
                self.ownerPtr().push(conn_handle, char_uuid, mode, &Chunk.ack_signal) catch {
                    self.mutex.lock();
                    self.clearWriteXStateLocked(conn_handle, service_uuid, char_uuid);
                    self.mutex.unlock();
                    return true;
                };
                invokeXferWriteHandler(route, conn_handle, service_uuid, char_uuid, data);
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

            self.sendReadXChunks(req.conn_handle, req.service_uuid, req.char_uuid, req.data) catch |err| {
                switch (err) {
                    error.InvalidSequence => {
                        self.mutex.lock();
                        self.clearReadXStateLocked(req.conn_handle, req.service_uuid, req.char_uuid);
                        self.mutex.unlock();
                        rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                    },
                    else => rw.err(@intFromEnum(att.ErrorCode.unlikely_error)),
                }
                return true;
            };
            rw.ok();
            return true;
        }

        fn invokeXferWriteHandler(route: Route, conn_handle: u16, service_uuid: u16, char_uuid: u16, data: []const u8) void {
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
        ) (bt.Peripheral.GattError || error{ InvalidSequence, MissingState })!void {
            self.mutex.lock();
            const conn = self.conns.getPtr(conn_handle) orelse {
                self.mutex.unlock();
                return error.MissingState;
            };
            const state = conn.read_x_states.get(charKey(service_uuid, char_uuid)) orelse {
                self.mutex.unlock();
                return error.MissingState;
            };
            self.mutex.unlock();

            var selected: [260]u16 = undefined;
            const seqs: []const u16 = if (loss_list) |list|
                selected[0..Chunk.decodeLossList(list, &selected)]
            else
                &.{};

            var chunk_buf: [Chunk.max_mtu]u8 = undefined;
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

        fn sendReadXChunk(
            self: *Self,
            state: ReadXState,
            seq: u16,
            chunk_buf: []u8,
        ) (bt.Peripheral.GattError || error{ InvalidSequence, MissingState })!void {
            if (seq == 0 or seq > state.total) return error.InvalidSequence;

            const hdr = (Chunk.Header{ .total = state.total, .seq = seq }).encode();
            @memcpy(chunk_buf[0..Chunk.header_size], &hdr);

            const offset = (@as(usize, seq) - 1) * state.dcs;
            const payload_len = if (state.data.len == 0)
                0
            else
                @min(state.data.len -| offset, state.dcs);
            if (payload_len > 0) {
                @memcpy(
                    chunk_buf[Chunk.header_size .. Chunk.header_size + payload_len],
                    state.data[offset .. offset + payload_len],
                );
            }

            try self.ownerPtr().push(
                state.conn_handle,
                state.char_uuid,
                state.mode,
                chunk_buf[0 .. Chunk.header_size + payload_len],
            );
        }

        fn sendWriteXLossList(
            self: *Self,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            mode: PushMode,
        ) bt.Peripheral.GattError!void {
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

            var buf: [Chunk.max_mtu]u8 = undefined;
            var missing: [Chunk.max_mtu / 2]u16 = undefined;
            var count: usize = 0;
            var seq: u16 = 1;
            while (seq <= state.total) : (seq += 1) {
                if (Chunk.Bitmask.isSet(state.rcvmask[0..Chunk.Bitmask.requiredBytes(state.total)], seq)) continue;
                missing[count] = seq;
                count += 1;
                if (count == missing.len) {
                    const encoded = Chunk.encodeLossList(missing[0..count], &buf);
                    try self.ownerPtr().push(conn_handle, char_uuid, mode, encoded);
                    count = 0;
                }
            }

            if (count != 0) {
                const encoded = Chunk.encodeLossList(missing[0..count], &buf);
                try self.ownerPtr().push(conn_handle, char_uuid, mode, encoded);
            }
        }

        fn subscriptionMode(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) ?PushMode {
            self.mutex.lock();
            defer self.mutex.unlock();

            const conn = self.conns.getPtr(conn_handle) orelse return null;
            return conn.push_modes.get(charKey(service_uuid, char_uuid));
        }

        fn resetXferStatesInConn(conn: *ConnState, allocator: lib.mem.Allocator) void {
            var read_iter = conn.read_x_states.iterator();
            while (read_iter.next()) |entry| {
                allocator.free(entry.value_ptr.request_metadata);
                allocator.free(entry.value_ptr.data);
            }

            var write_iter = conn.write_x_states.iterator();
            while (write_iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }

            conn.read_x_states.clearRetainingCapacity();
            conn.write_x_states.clearRetainingCapacity();
        }

        fn clearReadXStateInConnLocked(self: *Self, conn: *ConnState, key: CharKey) void {
            const state = conn.read_x_states.get(key) orelse return;
            _ = conn.read_x_states.remove(key);
            self.allocator.free(state.request_metadata);
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
            self.idle_watchdog_cond.broadcast();
        }

        fn clearWriteXStateLocked(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) void {
            const conn = self.conns.getPtr(conn_handle) orelse return;
            self.clearWriteXStateInConnLocked(conn, charKey(service_uuid, char_uuid));
            self.pruneConnIfEmptyLocked(conn_handle);
        }

        fn startIdleWatchdog(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) void {
            const t = lib.Thread.spawn(.{}, writeXIdleWatchdog, .{ self, conn_handle, service_uuid, char_uuid }) catch {
                self.mutex.lock();
                self.idle_watchdog_count -= 1;
                if (self.conns.getPtr(conn_handle)) |conn| {
                    if (conn.write_x_states.getPtr(charKey(service_uuid, char_uuid))) |state| {
                        state.watchdog_active = false;
                    }
                }
                self.idle_watchdog_cond.broadcast();
                self.mutex.unlock();
                return;
            };
            t.detach();
        }

        fn writeXIdleWatchdog(self: *Self, conn_handle: u16, service_uuid: u16, char_uuid: u16) void {
            defer {
                self.mutex.lock();
                self.idle_watchdog_count -= 1;
                self.idle_watchdog_cond.broadcast();
                self.mutex.unlock();
            }

            const timeout_ms = self.write_idle_timeout_ms;
            const timeout_ns = @as(u64, timeout_ms) * lib.time.ns_per_ms;
            var retries: u8 = 0;
            const key = charKey(service_uuid, char_uuid);

            self.mutex.lock();
            while (retries < max_idle_retries) {
                self.idle_watchdog_cond.timedWait(&self.mutex, timeout_ns) catch {};

                if (self.closing) {
                    self.mutex.unlock();
                    return;
                }

                const conn = self.conns.getPtr(conn_handle) orelse {
                    self.mutex.unlock();
                    return;
                };
                const state = conn.write_x_states.getPtr(key) orelse {
                    self.mutex.unlock();
                    return;
                };

                if (!state.initialized) continue;

                const now = lib.time.milliTimestamp();
                if (now - state.last_recv_ts < @as(i64, timeout_ms)) continue;

                const mask_len = Chunk.Bitmask.requiredBytes(state.total);
                if (Chunk.Bitmask.isComplete(state.rcvmask[0..mask_len], state.total)) {
                    self.mutex.unlock();
                    return;
                }

                const mode = state.mode;
                self.mutex.unlock();

                retries += 1;
                self.sendWriteXLossList(conn_handle, service_uuid, char_uuid, mode) catch {
                    self.mutex.lock();
                    self.clearWriteXStateLocked(conn_handle, service_uuid, char_uuid);
                    self.mutex.unlock();
                    return;
                };

                self.mutex.lock();
            }

            self.clearWriteXStateLocked(conn_handle, service_uuid, char_uuid);
            self.mutex.unlock();
        }
    };
}

test "bt/unit_tests/host/xfer/Server/sendWriteXLossList_pages_large_loss_lists" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum {
            notify,
            indicate,
        };

        payloads: [4][Chunk.max_mtu]u8 = undefined,
        lens: [4]usize = [_]usize{0} ** 4,
        count: usize = 0,

        fn push(self: *@This(), conn_handle: u16, char_uuid: u16, mode: PushMode, data: []const u8) !void {
            _ = conn_handle;
            _ = char_uuid;
            _ = mode;
            @memcpy(self.payloads[self.count][0..data.len], data);
            self.lens[self.count] = data.len;
            self.count += 1;
        }
    };

    const Engine = Server(std, FakeHost);

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    const key = Engine.charKey(0x180D, 0x2A57);
    try conn.write_x_states.put(std.testing.allocator, key, .{
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .mode = .notify,
        .total = 300,
        .initialized = true,
    });
    const state = conn.write_x_states.getPtr(key).?;
    Chunk.Bitmask.initClear(state.rcvmask[0..Chunk.Bitmask.requiredBytes(300)], 300);

    try engine.sendWriteXLossList(1, 0x180D, 0x2A57, .notify);
    try std.testing.expectEqual(@as(usize, 2), host.count);

    var recovered: [300]u16 = undefined;
    var recovered_len: usize = 0;
    var decoded: [Chunk.max_mtu / 2]u16 = undefined;
    for (0..host.count) |i| {
        const count = Chunk.decodeLossList(host.payloads[i][0..host.lens[i]], &decoded);
        @memcpy(recovered[recovered_len .. recovered_len + count], decoded[0..count]);
        recovered_len += count;
    }

    try std.testing.expectEqual(@as(usize, 300), recovered_len);
    for (recovered, 0..) |seq, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i + 1)), seq);
    }
}

test "bt/unit_tests/host/xfer/Server/handleXReadStart_preserves_state_when_initial_push_fails" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum {
            notify,
            indicate,
        };

        push_calls: usize = 0,
        fail_push: bool = true,

        fn push(self: *@This(), _: u16, _: u16, _: PushMode, _: []const u8) !void {
            self.push_calls += 1;
            if (self.fail_push) return error.AttError;
        }
    };
    const Engine = Server(std, FakeHost);

    const RwState = struct {
        ok_calls: usize = 0,
        err_code: ?u8 = null,

        fn writeFn(_: *anyopaque, _: []const u8) void {}

        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }

        fn errFn(ptr: *anyopaque, code: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.err_code = code;
        }
    };

    const HandlerState = struct {
        fn handle(_: ?*anyopaque, _: *const Engine.ReadXRequest, rw: *Engine.ReadXResponseWriter) void {
            rw.write("hello");
        }
    };

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    try conn.push_modes.put(std.testing.allocator, Engine.charKey(0x180D, 0x2A57), .notify);

    const route: Engine.Route = .{
        .callbacks = .{ .read = HandlerState.handle },
        .ctx = null,
    };

    var rw_state = RwState{};
    var rw = bt.Peripheral.ResponseWriter{
        ._impl = &rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    const req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = &Chunk.read_start_magic,
    };

    engine.handleXReadStart(route, &req, &rw);

    try std.testing.expectEqual(@as(usize, 1), rw_state.ok_calls);
    try std.testing.expectEqual(@as(?u8, null), rw_state.err_code);
    try std.testing.expectEqual(@as(usize, 1), host.push_calls);
    try std.testing.expect(conn.read_x_states.get(Engine.charKey(0x180D, 0x2A57)) != null);
}

test "bt/unit_tests/host/xfer/Server/handleXReadStart_splits_topic_and_metadata" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum {
            notify,
            indicate,
        };

        fn push(_: *@This(), _: u16, _: u16, _: PushMode, _: []const u8) !void {}
    };
    const Engine = Server(std, FakeHost);

    const RwState = struct {
        ok_calls: usize = 0,
        err_code: ?u8 = null,

        fn writeFn(_: *anyopaque, _: []const u8) void {}

        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }

        fn errFn(ptr: *anyopaque, code: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.err_code = code;
        }
    };

    const HandlerState = struct {
        seen_topic: ?Chunk.Topic = null,
        seen_metadata: [3]u8 = [_]u8{0} ** 3,
        metadata_len: usize = 0,

        fn handle(ctx: ?*anyopaque, req: *const Engine.ReadXRequest, rw: *Engine.ReadXResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.seen_topic = req.topic;
            self.metadata_len = @min(self.seen_metadata.len, req.metadata.len);
            @memcpy(self.seen_metadata[0..self.metadata_len], req.metadata[0..self.metadata_len]);
            rw.write("ok");
        }
    };

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    try conn.push_modes.put(std.testing.allocator, Engine.charKey(0x180D, 0x2A57), .notify);

    var handler_state = HandlerState{};
    const route: Engine.Route = .{
        .callbacks = .{ .read = HandlerState.handle },
        .ctx = &handler_state,
    };

    var rw_state = RwState{};
    var rw = bt.Peripheral.ResponseWriter{
        ._impl = &rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };

    var payload: [Chunk.read_start_magic.len + Chunk.topic_size + 3]u8 = undefined;
    @memcpy(payload[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    const encoded = Chunk.encodeReadStartMetadata(
        payload[Chunk.read_start_magic.len..],
        0x0102030405060708,
        &.{ 0xAA, 0xBB, 0xCC },
    );
    const req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = payload[0 .. Chunk.read_start_magic.len + encoded.len],
    };

    engine.handleXReadStart(route, &req, &rw);

    try std.testing.expectEqual(@as(usize, 1), rw_state.ok_calls);
    try std.testing.expectEqual(@as(?u8, null), rw_state.err_code);
    try std.testing.expectEqual(@as(?Chunk.Topic, 0x0102030405060708), handler_state.seen_topic);
    try std.testing.expectEqual(@as(usize, 3), handler_state.metadata_len);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, handler_state.seen_metadata[0..handler_state.metadata_len]);
}

test "bt/unit_tests/host/xfer/Server/handleXReadStart_replays_same_request_but_rejects_different_active_request" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum {
            notify,
            indicate,
        };

        push_calls: usize = 0,

        fn push(self: *@This(), _: u16, _: u16, _: PushMode, _: []const u8) !void {
            self.push_calls += 1;
        }
    };
    const Engine = Server(std, FakeHost);

    const RwState = struct {
        ok_calls: usize = 0,
        err_code: ?u8 = null,

        fn writeFn(_: *anyopaque, _: []const u8) void {}

        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }

        fn errFn(ptr: *anyopaque, code: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.err_code = code;
        }
    };

    const HandlerState = struct {
        calls: usize = 0,

        fn handle(ctx: ?*anyopaque, _: *const Engine.ReadXRequest, rw: *Engine.ReadXResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            rw.write("fresh");
        }
    };

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    const key = Engine.charKey(0x180D, 0x2A57);
    try conn.push_modes.put(std.testing.allocator, key, .notify);
    const payload = try std.testing.allocator.dupe(u8, "cached");
    const request_metadata = try std.testing.allocator.dupe(u8, "alpha?");
    try conn.read_x_states.put(std.testing.allocator, key, .{
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .mode = .notify,
        .topic = 0x0102030405060708,
        .request_metadata = request_metadata,
        .data = payload,
        .total = 1,
        .dcs = payload.len,
    });

    var handler_state = HandlerState{};
    const route: Engine.Route = .{
        .callbacks = .{ .read = HandlerState.handle },
        .ctx = &handler_state,
    };

    var same_rw_state = RwState{};
    var same_rw = bt.Peripheral.ResponseWriter{
        ._impl = &same_rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    var same_payload: [Chunk.read_start_magic.len + Chunk.topic_size + 6]u8 = undefined;
    @memcpy(same_payload[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    const same_encoded = Chunk.encodeReadStartMetadata(
        same_payload[Chunk.read_start_magic.len..],
        0x0102030405060708,
        "alpha?",
    );
    const same_req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = same_payload[0 .. Chunk.read_start_magic.len + same_encoded.len],
    };

    engine.handleXReadStart(route, &same_req, &same_rw);
    try std.testing.expectEqual(@as(usize, 0), handler_state.calls);
    try std.testing.expectEqual(@as(usize, 1), same_rw_state.ok_calls);
    try std.testing.expectEqual(@as(?u8, null), same_rw_state.err_code);
    try std.testing.expectEqual(@as(usize, 1), host.push_calls);

    var different_rw_state = RwState{};
    var different_rw = bt.Peripheral.ResponseWriter{
        ._impl = &different_rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    var different_payload: [Chunk.read_start_magic.len + Chunk.topic_size + 5]u8 = undefined;
    @memcpy(different_payload[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    const different_encoded = Chunk.encodeReadStartMetadata(
        different_payload[Chunk.read_start_magic.len..],
        0x1112131415161718,
        "beta!",
    );
    const different_req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = different_payload[0 .. Chunk.read_start_magic.len + different_encoded.len],
    };

    engine.handleXReadStart(route, &different_req, &different_rw);
    try std.testing.expectEqual(@as(usize, 0), handler_state.calls);
    try std.testing.expectEqual(@as(usize, 0), different_rw_state.ok_calls);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(att.ErrorCode.request_not_supported)), different_rw_state.err_code);
    try std.testing.expectEqual(@as(usize, 1), host.push_calls);
    const active = conn.read_x_states.get(key) orelse return error.MissingReadState;
    try std.testing.expectEqual(@as(?Chunk.Topic, 0x0102030405060708), active.topic);
    try std.testing.expectEqualSlices(u8, "alpha?", active.request_metadata);

    var same_topic_rw_state = RwState{};
    var same_topic_rw = bt.Peripheral.ResponseWriter{
        ._impl = &same_topic_rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    var same_topic_payload: [Chunk.read_start_magic.len + Chunk.topic_size + 8]u8 = undefined;
    @memcpy(same_topic_payload[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    const same_topic_encoded = Chunk.encodeReadStartMetadata(
        same_topic_payload[Chunk.read_start_magic.len..],
        0x0102030405060708,
        "changed!",
    );
    const same_topic_req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = same_topic_payload[0 .. Chunk.read_start_magic.len + same_topic_encoded.len],
    };

    engine.handleXReadStart(route, &same_topic_req, &same_topic_rw);
    try std.testing.expectEqual(@as(usize, 0), handler_state.calls);
    try std.testing.expectEqual(@as(usize, 0), same_topic_rw_state.ok_calls);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(att.ErrorCode.request_not_supported)), same_topic_rw_state.err_code);
    try std.testing.expectEqual(@as(usize, 1), host.push_calls);
}

test "bt/unit_tests/host/xfer/Server/handleXWriteChunk_ack_failure_clears_state_before_handler" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum {
            notify,
            indicate,
        };

        push_calls: usize = 0,
        fail_push: bool = true,

        fn push(self: *@This(), _: u16, _: u16, _: PushMode, data: []const u8) !void {
            self.push_calls += 1;
            try std.testing.expectEqualSlices(u8, &Chunk.ack_signal, data);
            if (self.fail_push) return error.AttError;
        }
    };
    const Engine = Server(std, FakeHost);

    const RwState = struct {
        ok_calls: usize = 0,
        err_code: ?u8 = null,

        fn writeFn(_: *anyopaque, _: []const u8) void {}

        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }

        fn errFn(ptr: *anyopaque, code: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.err_code = code;
        }
    };

    const HandlerState = struct {
        calls: usize = 0,

        fn handle(ctx: ?*anyopaque, _: *const Engine.WriteXRequest) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    try conn.push_modes.put(std.testing.allocator, Engine.charKey(0x180D, 0x2A57), .notify);

    var handler_state = HandlerState{};
    const route: Engine.Route = .{
        .callbacks = .{ .write = HandlerState.handle },
        .ctx = &handler_state,
    };

    var rw_state = RwState{};
    var rw = bt.Peripheral.ResponseWriter{
        ._impl = &rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    const start_req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = &Chunk.write_start_magic,
    };
    engine.handleXWriteStart(route, &start_req, &rw);

    var chunk: [Chunk.header_size + 3]u8 = undefined;
    const hdr = (Chunk.Header{ .total = 1, .seq = 1 }).encode();
    @memcpy(chunk[0..Chunk.header_size], &hdr);
    @memcpy(chunk[Chunk.header_size..], "hey");
    const chunk_req: bt.Peripheral.Request = .{
        .op = .write_without_response,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = &chunk,
    };

    try std.testing.expect(engine.handleXWriteChunk(route, &chunk_req, &rw));
    try std.testing.expectEqual(@as(usize, 2), rw_state.ok_calls);
    try std.testing.expectEqual(@as(?u8, null), rw_state.err_code);
    try std.testing.expectEqual(@as(usize, 0), handler_state.calls);
    try std.testing.expectEqual(@as(usize, 1), host.push_calls);
    try std.testing.expect(conn.write_x_states.get(Engine.charKey(0x180D, 0x2A57)) == null);

    engine.handleXWriteStart(route, &start_req, &rw);
    host.fail_push = false;
    try std.testing.expect(engine.handleXWriteChunk(route, &chunk_req, &rw));
    try std.testing.expectEqual(@as(usize, 4), rw_state.ok_calls);
    try std.testing.expectEqual(@as(usize, 1), handler_state.calls);
    try std.testing.expectEqual(@as(usize, 2), host.push_calls);
    try std.testing.expect(conn.write_x_states.get(Engine.charKey(0x180D, 0x2A57)) == null);
}

test "bt/unit_tests/host/xfer/Server/handleXReadLossList_rejects_out_of_range_sequences" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum {
            notify,
            indicate,
        };

        fn push(_: *@This(), _: u16, _: u16, _: PushMode, _: []const u8) !void {}
    };

    const RwState = struct {
        ok_calls: usize = 0,
        err_code: ?u8 = null,

        fn writeFn(_: *anyopaque, _: []const u8) void {}

        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }

        fn errFn(ptr: *anyopaque, code: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.err_code = code;
        }
    };

    const Engine = Server(std, FakeHost);

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    const payload = try std.testing.allocator.dupe(u8, "abcdef");
    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    try conn.read_x_states.put(std.testing.allocator, Engine.charKey(0x180D, 0x2A57), .{
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .mode = .notify,
        .topic = null,
        .request_metadata = try std.testing.allocator.dupe(u8, &.{}),
        .data = payload,
        .total = 2,
        .dcs = 3,
    });

    var loss_buf: [2]u8 = undefined;
    const encoded = Chunk.encodeLossList(&.{3}, &loss_buf);

    var rw_state = RwState{};
    var rw = bt.Peripheral.ResponseWriter{
        ._impl = &rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    const req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = encoded,
    };

    try std.testing.expect(engine.handleXReadLossList(&req, &rw));
    try std.testing.expectEqual(@as(usize, 0), rw_state.ok_calls);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(att.ErrorCode.invalid_attribute_value_length)), rw_state.err_code);
    try std.testing.expect(conn.read_x_states.get(Engine.charKey(0x180D, 0x2A57)) == null);
}

test "bt/unit_tests/host/xfer/Server/handleXWriteStart_uses_connection_att_mtu" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum {
            notify,
            indicate,
        };

        fn push(_: *@This(), _: u16, _: u16, _: PushMode, _: []const u8) !void {}
    };

    const RwState = struct {
        ok_calls: usize = 0,
        err_code: ?u8 = null,

        fn writeFn(_: *anyopaque, _: []const u8) void {}

        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }

        fn errFn(ptr: *anyopaque, code: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.err_code = code;
        }
    };

    const Engine = Server(std, FakeHost);

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{ .att_mtu = 64 });
    const conn = engine.conns.getPtr(1).?;
    try conn.push_modes.put(std.testing.allocator, Engine.charKey(0x180D, 0x2A57), .notify);

    const route: Engine.Route = .{
        .callbacks = .{
            .write = struct {
                fn handle(_: ?*anyopaque, _: *const Engine.WriteXRequest) void {}
            }.handle,
        },
        .ctx = null,
    };

    var rw_state = RwState{};
    var rw = bt.Peripheral.ResponseWriter{
        ._impl = &rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    const req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = &Chunk.write_start_magic,
    };

    engine.handleXWriteStart(route, &req, &rw);

    try std.testing.expectEqual(@as(usize, 1), rw_state.ok_calls);
    try std.testing.expectEqual(@as(?u8, null), rw_state.err_code);
    const state = conn.write_x_states.get(Engine.charKey(0x180D, 0x2A57)) orelse return error.NoWriteState;
    try std.testing.expectEqual(Chunk.dataChunkSize(64), state.dcs);
}

test "bt/unit_tests/host/xfer/Server/idle_watchdog_sends_loss_list_on_timeout" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum { notify, indicate };

        mutex: std.Thread.Mutex = .{},
        payloads: [8][Chunk.max_mtu]u8 = undefined,
        lens: [8]usize = [_]usize{0} ** 8,
        count: usize = 0,

        fn push(self: *@This(), _: u16, _: u16, _: PushMode, data: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            @memcpy(self.payloads[self.count][0..data.len], data);
            self.lens[self.count] = data.len;
            self.count += 1;
        }
    };

    const RwState = struct {
        ok_calls: usize = 0,
        err_code: ?u8 = null,
        fn writeFn(_: *anyopaque, _: []const u8) void {}
        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }
        fn errFn(ptr: *anyopaque, code: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.err_code = code;
        }
    };

    const Engine = Server(std, FakeHost);

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    try conn.push_modes.put(std.testing.allocator, Engine.charKey(0x180D, 0x2A57), .notify);

    const route: Engine.Route = .{
        .callbacks = .{
            .write = struct {
                fn handle(_: ?*anyopaque, _: *const Engine.WriteXRequest) void {}
            }.handle,
        },
        .ctx = null,
    };

    // Send write start magic
    var rw_state = RwState{};
    var rw = bt.Peripheral.ResponseWriter{
        ._impl = &rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    const start_req: bt.Peripheral.Request = .{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = &Chunk.write_start_magic,
    };
    engine.handleXWriteStart(route, &start_req, &rw);
    try std.testing.expectEqual(@as(usize, 1), rw_state.ok_calls);

    // Send chunk 1 of 3 (only this one — simulate chunks 2,3 lost including last)
    const dcs = Chunk.dataChunkSize(att.DEFAULT_MTU);
    const total: u16 = 3;
    const hdr = (Chunk.Header{ .total = total, .seq = 1 }).encode();
    var chunk_data: [Chunk.header_size + 17]u8 = undefined;
    @memcpy(chunk_data[0..Chunk.header_size], &hdr);
    for (chunk_data[Chunk.header_size..]) |*b| b.* = 0xAB;
    const chunk_len = Chunk.header_size + @min(dcs, 17);

    var rw_state2 = RwState{};
    var rw2 = bt.Peripheral.ResponseWriter{
        ._impl = &rw_state2,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    const chunk_req: bt.Peripheral.Request = .{
        .op = .write_without_response,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = chunk_data[0..chunk_len],
    };
    const handled = engine.handleXWriteChunk(route, &chunk_req, &rw2);
    try std.testing.expect(handled);

    // Verify watchdog was armed
    engine.mutex.lock();
    const ws = conn.write_x_states.getPtr(Engine.charKey(0x180D, 0x2A57)).?;
    try std.testing.expect(ws.watchdog_active);
    try std.testing.expect(ws.initialized);
    try std.testing.expectEqual(@as(u32, 1), engine.idle_watchdog_count);
    engine.mutex.unlock();

    // Wait for idle timeout to fire (default 1000ms + margin)
    std.time.sleep(1500 * std.time.ns_per_ms);

    // Verify the watchdog sent a loss list via push
    host.mutex.lock();
    const push_count = host.count;
    host.mutex.unlock();

    try std.testing.expect(push_count >= 1);

    // Decode pushed data and verify it's a loss list containing seq 2 and 3
    var decoded: [Chunk.max_mtu / 2]u16 = undefined;
    const loss_count = Chunk.decodeLossList(host.payloads[0][0..host.lens[0]], &decoded);
    try std.testing.expectEqual(@as(usize, 2), loss_count);
    try std.testing.expectEqual(@as(u16, 2), decoded[0]);
    try std.testing.expectEqual(@as(u16, 3), decoded[1]);
}

test "bt/unit_tests/host/xfer/Server/idle_watchdog_exits_when_transfer_completes" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum { notify, indicate };

        mutex: std.Thread.Mutex = .{},
        count: usize = 0,

        fn push(self: *@This(), _: u16, _: u16, _: PushMode, _: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.count += 1;
        }
    };

    const RwState = struct {
        ok_calls: usize = 0,
        fn writeFn(_: *anyopaque, _: []const u8) void {}
        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }
        fn errFn(_: *anyopaque, _: u8) void {}
    };

    const Engine = Server(std, FakeHost);

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    try conn.push_modes.put(std.testing.allocator, Engine.charKey(0x180D, 0x2A57), .notify);

    const route: Engine.Route = .{
        .callbacks = .{
            .write = struct {
                fn handle(_: ?*anyopaque, _: *const Engine.WriteXRequest) void {}
            }.handle,
        },
        .ctx = null,
    };

    // Write start
    var rw_state = RwState{};
    var rw = bt.Peripheral.ResponseWriter{
        ._impl = &rw_state,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    engine.handleXWriteStart(route, &(bt.Peripheral.Request{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = &Chunk.write_start_magic,
    }), &rw);

    const dcs = Chunk.dataChunkSize(att.DEFAULT_MTU);
    const total: u16 = 2;

    // Send chunk 1 of 2 (triggers watchdog)
    const hdr1 = (Chunk.Header{ .total = total, .seq = 1 }).encode();
    var c1: [Chunk.header_size + 17]u8 = undefined;
    @memcpy(c1[0..Chunk.header_size], &hdr1);
    for (c1[Chunk.header_size..]) |*b| b.* = 0x11;
    var rw2 = RwState{};
    var rw2w = bt.Peripheral.ResponseWriter{
        ._impl = &rw2,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    _ = engine.handleXWriteChunk(route, &(bt.Peripheral.Request{
        .op = .write_without_response,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = c1[0 .. Chunk.header_size + @min(dcs, 17)],
    }), &rw2w);

    // Now send chunk 2 (last chunk) — completes the transfer
    const hdr2 = (Chunk.Header{ .total = total, .seq = 2 }).encode();
    var c2: [Chunk.header_size + 17]u8 = undefined;
    @memcpy(c2[0..Chunk.header_size], &hdr2);
    for (c2[Chunk.header_size..]) |*b| b.* = 0x22;
    var rw3 = RwState{};
    var rw3w = bt.Peripheral.ResponseWriter{
        ._impl = &rw3,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    _ = engine.handleXWriteChunk(route, &(bt.Peripheral.Request{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = c2[0 .. Chunk.header_size + @min(dcs, 17)],
    }), &rw3w);

    // State should be cleared (ACK sent, transfer complete)
    engine.mutex.lock();
    const state_gone = conn.write_x_states.get(Engine.charKey(0x180D, 0x2A57)) == null;
    engine.mutex.unlock();
    try std.testing.expect(state_gone);

    // Wait briefly — watchdog should exit cleanly (state gone)
    std.time.sleep(200 * std.time.ns_per_ms);

    engine.mutex.lock();
    try std.testing.expectEqual(@as(u32, 0), engine.idle_watchdog_count);
    engine.mutex.unlock();

    // Push should have the ACK (from completing the transfer), not a loss list
    host.mutex.lock();
    const push_count = host.count;
    host.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), push_count);
}

test "bt/unit_tests/host/xfer/Server/idle_watchdog_exits_on_disconnect" {
    const std = @import("std");

    const FakeHost = struct {
        pub const PushMode = enum { notify, indicate };
        fn push(_: *@This(), _: u16, _: u16, _: PushMode, _: []const u8) !void {}
    };

    const RwState = struct {
        ok_calls: usize = 0,
        fn writeFn(_: *anyopaque, _: []const u8) void {}
        fn okFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ok_calls += 1;
        }
        fn errFn(_: *anyopaque, _: u8) void {}
    };

    const Engine = Server(std, FakeHost);

    var host = FakeHost{};
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();
    engine.bind(&host);

    try engine.conns.put(std.testing.allocator, 1, .{});
    const conn = engine.conns.getPtr(1).?;
    try conn.push_modes.put(std.testing.allocator, Engine.charKey(0x180D, 0x2A57), .notify);

    const route: Engine.Route = .{
        .callbacks = .{
            .write = struct {
                fn handle(_: ?*anyopaque, _: *const Engine.WriteXRequest) void {}
            }.handle,
        },
        .ctx = null,
    };

    // Write start + one chunk to arm watchdog
    var rw = RwState{};
    var rww = bt.Peripheral.ResponseWriter{
        ._impl = &rw,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    engine.handleXWriteStart(route, &(bt.Peripheral.Request{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = &Chunk.write_start_magic,
    }), &rww);

    const dcs = Chunk.dataChunkSize(att.DEFAULT_MTU);
    const hdr = (Chunk.Header{ .total = 5, .seq = 1 }).encode();
    var cd: [Chunk.header_size + 17]u8 = undefined;
    @memcpy(cd[0..Chunk.header_size], &hdr);
    for (cd[Chunk.header_size..]) |*b| b.* = 0xFF;
    var rw2 = RwState{};
    var rw2w = bt.Peripheral.ResponseWriter{
        ._impl = &rw2,
        ._write_fn = RwState.writeFn,
        ._ok_fn = RwState.okFn,
        ._err_fn = RwState.errFn,
    };
    _ = engine.handleXWriteChunk(route, &(bt.Peripheral.Request{
        .op = .write_without_response,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A57,
        .data = cd[0 .. Chunk.header_size + @min(dcs, 17)],
    }), &rw2w);

    engine.mutex.lock();
    try std.testing.expectEqual(@as(u32, 1), engine.idle_watchdog_count);
    engine.mutex.unlock();

    // Simulate disconnect — should wake watchdog and cause it to exit
    engine.handleDisconnect(1);

    std.time.sleep(200 * std.time.ns_per_ms);

    engine.mutex.lock();
    try std.testing.expectEqual(@as(u32, 0), engine.idle_watchdog_count);
    engine.mutex.unlock();
}
