//! host.server.Receiver — server helper for xfer.write clients.
//!
//! A Receiver instance is bound to one xfer characteristic. Clients initiate a
//! transfer with `xfer.write(...)`, which writes a `write_start` packet plus
//! chunk payloads into this characteristic. The receiver rebuilds the payload
//! with `xfer.recv(...)` and dispatches the final bytes to one handler.

const glib = @import("glib");

const bt = @import("../../../bt.zig");
const att = @import("../att.zig");
const xfer = @import("../xfer.zig");
const Chunk = xfer.Chunk;

pub const Request = struct {
    conn_handle: u16,
    service_uuid: u16,
    char_uuid: u16,
    data: []const u8,
};

pub const HandlerFn = *const fn (?*anyopaque, *const Request) void;

pub fn make(comptime grt: type, comptime ServerType: type) type {
    return struct {
        const Self = @This();
        const Inbox = ServerType.ChannelFactory([]u8);
        const Subscription = ServerType.Subscription;

        const Session = struct {
            mux: *Self,
            subscription: Subscription,
            conn_handle: u16,
            mutex: grt.std.Thread.Mutex = .{},
            closed: bool = false,
            ref_count: usize = 1,
            inbox: Inbox,
            thread: ?grt.std.Thread = null,
            worker_id: ?grt.std.Thread.Id = null,

            const Transport = struct {
                session: *Session,

                pub fn read(self: *@This(), timeout: glib.time.duration.Duration, out: []u8) !usize {
                    const recv_res = try self.session.inbox.recvTimeout(timeout);
                    if (!recv_res.ok) return error.Closed;

                    var payload = recv_res.value;
                    defer self.session.destroyData(&payload);

                    if (payload.len > out.len) return error.NoSpaceLeft;
                    @memcpy(out[0..payload.len], payload);
                    return payload.len;
                }

                pub fn write(self: *@This(), data: []const u8) !usize {
                    if (self.session.subscription.canNotify()) {
                        try self.session.subscription.notify(data);
                    } else {
                        try self.session.subscription.indicate(data);
                    }
                    return data.len;
                }

                pub fn deinit(self: *@This()) void {
                    _ = self;
                }
            };

            fn init(allocator: glib.std.mem.Allocator, mux: *Self, subscription: Subscription) !*@This() {
                const self = try allocator.create(@This());
                errdefer allocator.destroy(self);

                var inbox = try Inbox.make(allocator, 64);
                errdefer inbox.deinit();

                self.* = .{
                    .mux = mux,
                    .subscription = subscription,
                    .conn_handle = subscription.connHandle(),
                    .inbox = inbox,
                };
                errdefer self.subscription.deinit();

                self.retain();
                self.thread = try grt.std.Thread.spawn(.{}, task, .{self});
                return self;
            }

            fn close(self: *@This()) void {
                self.mutex.lock();
                self.closed = true;
                self.mutex.unlock();
                self.inbox.close();
            }

            fn finishTx(self: *@This()) void {
                self.close();
                if (self.mux.removeSession(self)) {
                    self.release(self.mux.allocator);
                }
            }

            fn dupData(self: *@This(), data: []const u8) ![]u8 {
                return if (data.len == 0)
                    &.{}
                else
                    try self.mux.allocator.dupe(u8, data);
            }

            fn destroyData(self: *@This(), payload: *[]u8) void {
                if (payload.len > 0) {
                    self.mux.allocator.free(payload.*);
                    payload.* = &.{};
                }
            }

            fn injectRequest(self: *@This(), req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
                switch (req.op) {
                    .write, .write_without_response => {},
                    else => {
                        rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                        return;
                    },
                }

                self.mutex.lock();
                const closed = self.closed;
                self.mutex.unlock();
                if (closed) {
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                }

                if (req.data.len > Chunk.max_mtu) {
                    rw.err(@intFromEnum(att.ErrorCode.invalid_attribute_value_length));
                    return;
                }

                var event = self.dupData(req.data) catch {
                    rw.err(@intFromEnum(att.ErrorCode.insufficient_resources));
                    return;
                };

                const send_res = self.inbox.send(event) catch {
                    self.destroyData(&event);
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                };
                if (!send_res.ok) {
                    self.destroyData(&event);
                    rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                    return;
                }

                rw.ok();
            }

            fn retain(self: *@This()) void {
                self.mutex.lock();
                self.ref_count += 1;
                self.mutex.unlock();
            }

            fn release(self: *@This(), allocator: glib.std.mem.Allocator) void {
                const current_thread = grt.std.Thread.getCurrentId();
                const thread: ?grt.std.Thread = blk: {
                    self.mutex.lock();
                    if (self.ref_count == 0) unreachable;
                    self.ref_count -= 1;
                    if (self.ref_count != 0) {
                        self.mutex.unlock();
                        return;
                    }
                    self.closed = true;
                    const join_thread = self.thread;
                    self.thread = null;
                    self.mutex.unlock();
                    break :blk join_thread;
                };

                self.inbox.close();
                if (thread) |t| {
                    if (self.worker_id == null or self.worker_id.? != current_thread) {
                        t.join();
                    }
                }
                self.worker_id = null;
                while (true) {
                    const recv_res = self.inbox.recv() catch break;
                    if (!recv_res.ok) break;
                    var event = recv_res.value;
                    self.destroyData(&event);
                }
                self.inbox.deinit();
                self.subscription.deinit();
                allocator.destroy(self);
            }

            fn task(self: *@This()) void {
                self.worker_id = grt.std.Thread.getCurrentId();
                defer self.release(self.mux.allocator);
                defer self.finishTx();

                var tx = Transport{ .session = self };
                const data = xfer.recv(grt, self.mux.allocator, &tx, .{
                    .att_mtu = self.subscription.attMtu(),
                    .timeout = 5 * glib.time.duration.Second,
                }) catch return;
                defer self.mux.allocator.free(data);

                self.mux.mutex.lock();
                const maybe_handler = self.mux.receive_handler;
                const handler_ctx = self.mux.handler_ctx;
                self.mux.mutex.unlock();
                const receive_handler = maybe_handler orelse return;

                var receive_req = Request{
                    .conn_handle = self.conn_handle,
                    .service_uuid = self.subscription.serviceUuid(),
                    .char_uuid = self.subscription.charUuid(),
                    .data = data,
                };
                receive_handler(handler_ctx, &receive_req);
            }
        };

        allocator: glib.std.mem.Allocator,
        mutex: grt.std.Thread.Mutex = .{},
        receive_handler: ?HandlerFn = null,
        handler_ctx: ?*anyopaque = null,
        sessions: grt.std.AutoHashMapUnmanaged(u16, *Session) = .{},

        pub fn init(allocator: glib.std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            var sessions = self.sessions;
            self.sessions = .{};
            self.receive_handler = null;
            self.handler_ctx = null;
            self.mutex.unlock();

            var conn_iter = sessions.iterator();
            while (conn_iter.next()) |entry| {
                entry.value_ptr.*.close();
                entry.value_ptr.*.release(self.allocator);
            }
            sessions.deinit(self.allocator);
        }

        pub fn start(self: *Self, sub: Subscription) !void {
            var subscription = sub;
            const conn_handle = subscription.connHandle();

            self.mutex.lock();
            const previous = self.sessions.get(conn_handle);
            if (previous != null) {
                _ = self.sessions.remove(conn_handle);
            }
            self.mutex.unlock();

            if (previous) |session| {
                session.close();
                session.release(self.allocator);
            }

            const session = Session.init(self.allocator, self, subscription) catch |err| {
                subscription.deinit();
                return err;
            };

            self.mutex.lock();
            self.sessions.put(self.allocator, conn_handle, session) catch |err| {
                self.mutex.unlock();
                session.close();
                session.release(self.allocator);
                return err;
            };
            self.mutex.unlock();
        }

        fn removeSession(self: *Self, session: *Session) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const active = self.sessions.get(session.conn_handle) orelse return false;
            if (active != session) return false;

            _ = self.sessions.remove(session.conn_handle);
            return true;
        }

        pub fn handle(self: *Self, receive_handler: HandlerFn, ctx: ?*anyopaque) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.receive_handler != null) return error.DuplicateHandler;
            self.receive_handler = receive_handler;
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
                active.retain();
            }
            self.mutex.unlock();

            if (session) |active| {
                active.close();
                active.release(self.allocator);
            }
        }

        pub fn dispatchRequest(self: *Self, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            self.mutex.lock();
            const session = self.sessions.get(req.conn_handle);
            if (session) |active| {
                active.retain();
            }
            self.mutex.unlock();

            if (session) |active| {
                defer active.release(self.allocator);
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

        pub fn onSubscription(ctx: ?*anyopaque, sub: Subscription) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.start(sub) catch {};
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
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
                        pub fn init(_: glib.std.mem.Allocator, _: usize) !@This() {
                            return .{};
                        }
                        pub fn deinit(_: *@This()) void {}
                        pub fn close(_: *@This()) void {}
                        pub fn recvTimeout(_: *@This(), _: glib.time.duration.Duration) !glib.sync.channel.RecvResult(T) {
                            return error.Unexpected;
                        }
                        pub fn recv(_: *@This()) !glib.sync.channel.RecvResult(T) {
                            return error.Unexpected;
                        }
                        pub fn send(_: *@This(), _: T) !glib.sync.channel.SendResult() {
                            return .{ .ok = true };
                        }
                        pub fn sendTimeout(_: *@This(), _: T, _: glib.time.duration.Duration) !glib.sync.channel.SendResult() {
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
                const ChannelFactoryImpl = glib.sync.channel.make(Dummy.Channel);

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

            const Impl = make(grt, FakeServer);
            var receiver = Impl.init(grt.std.testing.allocator);
            defer receiver.deinit();

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
                .char_uuid = 0x2A59,
                .data = &Chunk.write_start_magic,
            };

            Impl.onRequest(&receiver, &req, &rw);

            try grt.std.testing.expectEqual(@as(usize, 0), writer_state.ok_count);
            try grt.std.testing.expectEqual(@as(?u8, @intFromEnum(att.ErrorCode.request_not_supported)), writer_state.err_code);
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
