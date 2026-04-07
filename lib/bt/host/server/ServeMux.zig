//! host.server.ServeMux — topic-routed server helper for xfer.read clients.
//!
//! A ServeMux instance is bound to one xfer characteristic. Clients initiate a
//! request with `xfer.read(...)`, which writes a `read_start` packet into this
//! characteristic and then waits for chunked replies via notify/indicate. The
//! mux creates one session per subscribed connection and feeds inbound control
//! packets into `xfer.send(...)`.

const embed = @import("embed");
const bt = @import("../../../bt.zig");
const att = @import("../att.zig");
const xfer = @import("../xfer.zig");
const Chunk = xfer.Chunk;

pub const Request = struct {
    conn_handle: u16,
    service_uuid: u16,
    char_uuid: u16,
    topic: Chunk.Topic,
    metadata: []const u8,
};

// Handlers return bytes allocated from the provided allocator, or `&.{}`.
pub const HandlerFn = *const fn (?*anyopaque, embed.mem.Allocator, *const Request) anyerror![]u8;

pub fn make(comptime lib: type, comptime ServerType: type) type {
    return struct {
        const Self = @This();
        const Subscription = ServerType.Subscription;
        const Inbox = ServerType.ChannelFactory([]u8);

        const Route = struct {
            handler: HandlerFn,
            ctx: ?*anyopaque,
        };

        allocator: lib.mem.Allocator,
        sessions: lib.AutoHashMapUnmanaged(u16, *Session) = .{},
        routes: lib.AutoHashMapUnmanaged(Chunk.Topic, Route) = .{},
        mutex: lib.Thread.Mutex = .{},

        pub fn init(allocator: lib.mem.Allocator) !Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            var sessions = self.sessions;
            self.sessions = .{};
            self.routes.deinit(self.allocator);
            self.routes = .{};
            self.mutex.unlock();

            var iter = sessions.iterator();
            while (iter.next()) |entry| {
                const session = entry.value_ptr.*;
                Session.close(session);
                Session.release(session);
            }
            sessions.deinit(self.allocator);
        }

        pub fn handle(self: *Self, topic: Chunk.Topic, read_handler: HandlerFn, ctx: ?*anyopaque) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.routes.contains(topic)) return error.DuplicateRoute;
            try self.routes.put(self.allocator, topic, .{
                .handler = read_handler,
                .ctx = ctx,
            });
        }

        pub fn handler(self: *Self) ServerType.Handler {
            _ = self;
            return .{
                .onRequest = onRequest,
                .onSubscription = onSubscription,
            };
        }

        fn onRequest(ctx: ?*anyopaque, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.dispatchRequest(req, rw);
        }

        fn onSubscription(ctx: ?*anyopaque, subscription: Subscription) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.replaceSession(subscription);
        }

        fn dispatchRequest(self: *Self, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            const session = self.retainSession(req.conn_handle) orelse {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };
            defer Session.release(session);
            session.injectRequest(req, rw);
        }

        fn replaceSession(self: *Self, subscription: Subscription) void {
            const session = Session.init(self, subscription) catch {
                var sub = subscription;
                sub.deinit();
                return;
            };

            self.mutex.lock();
            const existing = self.sessions.get(session.conn_handle);
            self.sessions.put(self.allocator, session.conn_handle, session) catch {
                self.mutex.unlock();
                Session.close(session);
                Session.release(session);
                return;
            };
            self.mutex.unlock();

            if (existing) |old| {
                Session.close(old);
                Session.release(old);
            }
        }

        fn retainSession(self: *Self, conn_handle: u16) ?*Session {
            self.mutex.lock();
            defer self.mutex.unlock();
            const session = self.sessions.get(conn_handle) orelse return null;
            Session.retain(session);
            return session;
        }

        fn removeSession(self: *Self, session: *Session) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            const existing = self.sessions.get(session.conn_handle) orelse return false;
            if (existing != session) return false;
            _ = self.sessions.remove(session.conn_handle);
            return true;
        }

        const Session = struct {
            mux: *Self,
            subscription: Subscription,
            conn_handle: u16,
            inbox: Inbox,
            thread: ?lib.Thread = null,
            worker_id: ?lib.Thread.Id = null,
            mutex: lib.Thread.Mutex = .{},
            closed: bool = false,
            ref_count: usize = 1,

            fn init(mux: *Self, subscription: Subscription) !*Session {
                const session = try mux.allocator.create(Session);
                errdefer mux.allocator.destroy(session);

                session.* = .{
                    .mux = mux,
                    .subscription = subscription,
                    .conn_handle = subscription.connHandle(),
                    .inbox = try Inbox.make(mux.allocator, 64),
                };
                errdefer session.inbox.deinit();
                errdefer session.subscription.deinit();

                retain(session);
                session.thread = try lib.Thread.spawn(.{}, task, .{session});
                return session;
            }

            fn close(self: *Session) void {
                self.mutex.lock();
                const already_closed = self.closed;
                self.closed = true;
                self.inbox.close();
                self.mutex.unlock();
                if (already_closed) return;
            }

            fn finishTx(self: *Session) void {
                self.close();
                if (self.mux.removeSession(self)) {
                    self.release();
                }
            }

            fn retain(self: *Session) void {
                self.mutex.lock();
                self.ref_count += 1;
                self.mutex.unlock();
            }

            fn release(self: *Session) void {
                const current_thread = lib.Thread.getCurrentId();
                const thread: ?lib.Thread = blk: {
                    self.mutex.lock();
                    if (self.ref_count == 0) unreachable;
                    self.ref_count -= 1;
                    if (self.ref_count != 0) {
                        self.mutex.unlock();
                        return;
                    }
                    self.closed = true;
                    self.inbox.close();
                    const join_thread = self.thread;
                    self.thread = null;
                    self.mutex.unlock();
                    break :blk join_thread;
                };

                if (thread) |t| {
                    if (self.worker_id == null or self.worker_id.? != current_thread) {
                        t.join();
                    }
                }

                self.worker_id = null;
                drainInbox(self.mux.allocator, &self.inbox);
                self.inbox.deinit();
                self.subscription.deinit();
                self.mux.allocator.destroy(self);
            }

            fn injectRequest(self: *Session, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
                switch (req.op) {
                    .write, .write_without_response => {},
                    else => {
                        rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                        return;
                    },
                }

                if (req.data.len > Chunk.max_mtu) {
                    rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                    return;
                }

                self.mutex.lock();
                const closed = self.closed;
                self.mutex.unlock();
                if (closed) {
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                }

                const payload_copy = self.dupData(req.data) catch {
                    rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                    return;
                };

                const send_res = self.inbox.send(payload_copy) catch {
                    self.destroyData(payload_copy);
                    rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                    return;
                };
                if (!send_res.ok) {
                    self.destroyData(payload_copy);
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                }

                rw.ok();
            }

            fn task(self: *Session) void {
                self.worker_id = lib.Thread.getCurrentId();
                defer release(self);
                defer self.finishTx();

                SessionSend.active_session = self;
                defer SessionSend.active_session = null;

                while (true) {
                    self.mutex.lock();
                    const closed = self.closed;
                    self.mutex.unlock();
                    if (closed) break;

                    var transport = Transport{ .session = self };
                    xfer.send(lib, self.mux.allocator, &transport, SessionSend.dataFn, .{
                        .att_mtu = self.subscription.attMtu(),
                        .send_redundancy = 1,
                    }) catch |err| {
                        if (err == error.Timeout) continue;
                        break;
                    };
                }
            }

            fn dupData(self: *Session, data: []const u8) ![]u8 {
                return self.mux.allocator.dupe(u8, data);
            }

            fn destroyData(self: *Session, data: []u8) void {
                self.mux.allocator.free(data);
            }

            const Transport = struct {
                session: *Session,

                pub fn connHandle(self: *@This()) u16 {
                    return self.session.subscription.connHandle();
                }

                pub fn serviceUuid(self: *@This()) u16 {
                    return self.session.subscription.serviceUuid();
                }

                pub fn charUuid(self: *@This()) u16 {
                    return self.session.subscription.charUuid();
                }

                pub fn read(self: *@This(), timeout_ms: u32, out: []u8) !usize {
                    const recv_res = try self.session.inbox.recvTimeout(timeout_ms);
                    if (!recv_res.ok) return error.Closed;

                    const payload = recv_res.value;
                    defer self.session.destroyData(payload);

                    if (payload.len > out.len) return error.NoSpaceLeft;
                    @memcpy(out[0..payload.len], payload);
                    return payload.len;
                }

                pub fn write(self: *@This(), data: []const u8) !usize {
                    try self.emit(data);
                    return data.len;
                }

                pub fn writeNoResp(self: *@This(), data: []const u8) !usize {
                    try self.emit(data);
                    return data.len;
                }

                pub fn deinit(self: *@This()) void {
                    _ = self;
                }

                fn emit(self: *@This(), data: []const u8) !void {
                    if (self.session.subscription.canNotify()) {
                        try self.session.subscription.notify(data);
                    } else {
                        try self.session.subscription.indicate(data);
                    }
                }
            };

            const SessionSend = struct {
                threadlocal var active_session: ?*Session = null;

                fn dataFn(
                    allocator: lib.mem.Allocator,
                    conn_handle: u16,
                    service_uuid: u16,
                    char_uuid: u16,
                    start: Chunk.ReadStartMetadata,
                ) ![]u8 {
                    const session = active_session orelse return error.Unexpected;
                    const topic = start.topic;

                    session.mux.mutex.lock();
                    const route = session.mux.routes.get(topic);
                    session.mux.mutex.unlock();
                    const matched = route orelse return error.AttributeNotFound;

                    var request = Request{
                        .conn_handle = conn_handle,
                        .service_uuid = service_uuid,
                        .char_uuid = char_uuid,
                        .topic = topic,
                        .metadata = start.metadata,
                    };
                    return matched.handler(matched.ctx, allocator, &request);
                }
            };
        };

        fn drainInbox(allocator: lib.mem.Allocator, inbox: *Inbox) void {
            while (true) {
                const recv_res = inbox.recv() catch break;
                if (!recv_res.ok) break;
                allocator.free(recv_res.value);
            }
        }
    };
}

test "bt/unit_tests/host/server/ServeMux/onRequest_without_session_returns_att_error" {
    const std = @import("std");

    const DummySubscription = struct {
        pub fn connHandle(_: *@This()) u16 {
            return 0;
        }

        pub fn serviceUuid(_: *@This()) u16 {
            return 0;
        }

        pub fn charUuid(_: *@This()) u16 {
            return 0;
        }

        pub fn attMtu(_: *@This()) u16 {
            return 23;
        }

        pub fn canNotify(_: *@This()) bool {
            return true;
        }

        pub fn notify(_: *@This(), _: []const u8) !void {}

        pub fn indicate(_: *@This(), _: []const u8) !void {}

        pub fn deinit(_: *@This()) void {}
    };

    const Dummy = struct {
        fn Channel(comptime T: type) type {
            return struct {
                pub fn make(_: std.mem.Allocator, _: usize) !@This() {
                    return .{};
                }

                pub fn deinit(_: *@This()) void {}
                pub fn close(_: *@This()) void {}
                pub fn recvTimeout(_: *@This(), _: u32) !struct { ok: bool, value: T } {
                    return error.Unexpected;
                }
                pub fn recv(_: *@This()) !struct { ok: bool, value: T } {
                    return error.Unexpected;
                }
                pub fn send(_: *@This(), _: T) !struct { ok: bool } {
                    return .{ .ok = true };
                }
            };
        }
    };

    const FakeServer = struct {
        pub const Subscription = DummySubscription;
        pub const Handler = struct {
            onRequest: ?*const fn (?*anyopaque, *const bt.Peripheral.Request, *bt.Peripheral.ResponseWriter) void = null,
            onSubscription: ?*const fn (?*anyopaque, Subscription) void = null,
        };

        pub fn ChannelFactory(comptime T: type) type {
            return Dummy.Channel(T);
        }
    };

    const WriterState = struct {
        ok_count: usize = 0,
        err_code: ?u8 = null,

        fn writeFn(_: *anyopaque, _: []const u8) void {}

        fn okFn(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ok_count += 1;
        }

        fn errFn(ctx: *anyopaque, code: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.err_code = code;
        }
    };

    const Impl = make(std, FakeServer);
    var mux = try Impl.init(std.testing.allocator);
    defer mux.deinit();

    var writer_state = WriterState{};
    var rw = bt.Peripheral.ResponseWriter{
        ._impl = &writer_state,
        ._write_fn = WriterState.writeFn,
        ._ok_fn = WriterState.okFn,
        ._err_fn = WriterState.errFn,
    };
    const req = bt.Peripheral.Request{
        .op = .write,
        .conn_handle = 1,
        .service_uuid = 0x180D,
        .char_uuid = 0x2A58,
        .data = &Chunk.read_start_magic,
    };

    mux.handler().onRequest.?(&mux, &req, &rw);

    try std.testing.expectEqual(@as(usize, 0), writer_state.ok_count);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(att.ErrorCode.request_not_supported)), writer_state.err_code);
}
