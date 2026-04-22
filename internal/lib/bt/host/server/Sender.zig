//! host.server.Sender — server helper for xfer.read clients.
//!
//! A Sender instance is bound to one xfer characteristic. Clients initiate a
//! transfer with `xfer.read(...)`, which writes a `read_start` packet into this
//! characteristic. The sender runs one read handler and streams the resulting
//! byte payload back with `xfer.send(...)`.

const bt = @import("../../../bt.zig");
const att = @import("../att.zig");
const sync = @import("sync");
const xfer = @import("../xfer.zig");
const Chunk = xfer.Chunk;
const testing_api = @import("testing");

pub const Request = struct {
    conn_handle: u16,
    service_uuid: u16,
    char_uuid: u16,
};

pub fn make(comptime lib: type, comptime ServerType: type) type {
    return struct {
        const Self = @This();
        const Inbox = ServerType.ChannelFactory([]u8);
        const Subscription = ServerType.Subscription;

        pub const HandlerFn = *const fn (?*anyopaque, lib.mem.Allocator, *const Request) anyerror![]u8;

        const Session = struct {
            sender: *Self,
            subscription: Subscription,
            conn_handle: u16,
            inbox: Inbox,
            thread: ?lib.Thread = null,
            worker_id: ?lib.Thread.Id = null,
            mutex: lib.Thread.Mutex = .{},
            closed: bool = false,
            ref_count: usize = 1,

            fn init(sender: *Self, subscription: Subscription) !*Session {
                const session = try sender.allocator.create(Session);
                errdefer sender.allocator.destroy(session);

                session.* = .{
                    .sender = sender,
                    .subscription = subscription,
                    .conn_handle = subscription.connHandle(),
                    .inbox = try Inbox.make(sender.allocator, 64),
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
                if (self.sender.removeSession(self)) {
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
                drainInbox(self.sender.allocator, &self.inbox);
                self.inbox.deinit();
                self.subscription.deinit();
                self.sender.allocator.destroy(self);
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

                var transport = Transport{ .session = self };
                xfer.send(lib, self.sender.allocator, &transport, @ptrCast(self), SessionSend.dataFn, .{
                    .att_mtu = self.subscription.attMtu(),
                    .send_redundancy = 1,
                }) catch {
                    return;
                };
            }

            fn dupData(self: *Session, data: []const u8) ![]u8 {
                return self.sender.allocator.dupe(u8, data);
            }

            fn destroyData(self: *Session, data: []u8) void {
                self.sender.allocator.free(data);
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
                fn dataFn(
                    ctx: ?*anyopaque,
                    allocator: lib.mem.Allocator,
                    conn_handle: u16,
                    service_uuid: u16,
                    char_uuid: u16,
                ) ![]u8 {
                    const session: *Session = @ptrCast(@alignCast(ctx orelse return error.Unexpected));

                    session.sender.mutex.lock();
                    const maybe_handler = session.sender.read_handler;
                    const handler_ctx = session.sender.handler_ctx;
                    session.sender.mutex.unlock();
                    const read_handler = maybe_handler orelse return error.AttributeNotFound;

                    var request = Request{
                        .conn_handle = conn_handle,
                        .service_uuid = service_uuid,
                        .char_uuid = char_uuid,
                    };
                    return read_handler(handler_ctx, allocator, &request);
                }
            };
        };

        allocator: lib.mem.Allocator,
        mutex: lib.Thread.Mutex = .{},
        read_handler: ?HandlerFn = null,
        handler_ctx: ?*anyopaque = null,
        sessions: lib.AutoHashMapUnmanaged(u16, *Session) = .{},

        pub fn init(allocator: lib.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            var sessions = self.sessions;
            self.sessions = .{};
            self.read_handler = null;
            self.handler_ctx = null;
            self.mutex.unlock();

            var conn_iter = sessions.iterator();
            while (conn_iter.next()) |entry| {
                entry.value_ptr.*.close();
                entry.value_ptr.*.release();
            }
            sessions.deinit(self.allocator);
        }

        pub fn start(self: *Self, subscription: Subscription) !void {
            const session = Session.init(self, subscription) catch |err| {
                var sub = subscription;
                sub.deinit();
                return err;
            };

            self.mutex.lock();
            const existing = self.sessions.get(session.conn_handle);
            self.sessions.put(self.allocator, session.conn_handle, session) catch |err| {
                self.mutex.unlock();
                session.close();
                session.release();
                return err;
            };
            self.mutex.unlock();

            if (existing) |old| {
                Session.close(old);
                Session.release(old);
            }
        }

        pub fn handle(self: *Self, read_handler: HandlerFn, ctx: ?*anyopaque) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.read_handler != null) return error.DuplicateHandler;
            self.read_handler = read_handler;
            self.handler_ctx = ctx;
        }

        pub fn hasActiveSession(self: *Self, conn_handle: u16) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.sessions.contains(conn_handle);
        }

        pub fn closeSession(self: *Self, conn_handle: u16) void {
            self.mutex.lock();
            const session = self.sessions.get(conn_handle);
            if (session) |active| {
                Session.retain(active);
            }
            self.mutex.unlock();

            if (session) |active| {
                active.close();
                active.release();
            }
        }

        pub fn dispatchRequest(self: *Self, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            self.mutex.lock();
            const session = self.sessions.get(req.conn_handle);
            if (session) |active| {
                Session.retain(active);
            }
            self.mutex.unlock();

            if (session) |active| {
                defer active.release();
                active.injectRequest(req, rw);
            } else {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
            }
        }

        pub fn handler() ServerType.Handler {
            return .{
                .onRequest = onRequest,
                .onSubscription = onSubscription,
            };
        }

        pub fn onRequest(ctx: ?*anyopaque, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.dispatchRequest(req, rw);
        }

        pub fn onSubscription(ctx: ?*anyopaque, subscription: Subscription) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.start(subscription) catch {};
        }

        fn removeSession(self: *Self, session: *Session) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const active = self.sessions.get(session.conn_handle) orelse return false;
            if (active != session) return false;

            _ = self.sessions.remove(session.conn_handle);
            return true;
        }

        fn drainInbox(allocator: lib.mem.Allocator, inbox: *Inbox) void {
            while (true) {
                const recv_res = inbox.recv() catch break;
                if (!recv_res.ok) break;
                allocator.free(recv_res.value);
            }
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const DummySubscription = struct {
                pub fn connHandle(_: *const @This()) u16 {
                    return 0;
                }
                pub fn serviceUuid(_: *const @This()) u16 {
                    return 0;
                }
                pub fn charUuid(_: *const @This()) u16 {
                    return 0;
                }
                pub fn attMtu(_: *const @This()) u16 {
                    return 23;
                }
                pub fn canNotify(_: *const @This()) bool {
                    return true;
                }
                pub fn notify(_: *const @This(), _: []const u8) !void {}
                pub fn indicate(_: *const @This(), _: []const u8) !void {}
                pub fn deinit(_: *const @This()) void {}
            };

            const Dummy = struct {
                fn Channel(comptime T: type) type {
                    return struct {
                        pub fn init(_: lib.mem.Allocator, _: usize) !@This() {
                            return .{};
                        }
                        pub fn deinit(_: *@This()) void {}
                        pub fn close(_: *@This()) void {}
                        pub fn recvTimeout(_: *@This(), _: u32) !sync.channel.RecvResult(T) {
                            return error.Unexpected;
                        }
                        pub fn recv(_: *@This()) !sync.channel.RecvResult(T) {
                            return error.Unexpected;
                        }
                        pub fn send(_: *@This(), _: T) !sync.channel.SendResult() {
                            return .{ .ok = true };
                        }
                        pub fn sendTimeout(_: *@This(), _: T, _: u32) !sync.channel.SendResult() {
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
                const ChannelFactoryImpl = sync.channel.make(Dummy.Channel);

                pub fn ChannelFactory(comptime T: type) type {
                    return ChannelFactoryImpl(T);
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

            const Impl = make(lib, FakeServer);
            var sender = Impl.init(lib.testing.allocator);
            defer sender.deinit();

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

            Impl.onRequest(&sender, &req, &rw);

            try lib.testing.expectEqual(@as(usize, 0), writer_state.ok_count);
            try lib.testing.expectEqual(@as(?u8, @intFromEnum(att.ErrorCode.request_not_supported)), writer_state.err_code);
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
