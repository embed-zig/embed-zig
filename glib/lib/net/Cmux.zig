const time_mod = @import("time");
const NetConn = @import("Conn.zig");
const NetListener = @import("Listener.zig");
const ChannelConn = @import("cmux/Conn.zig");
const control = @import("cmux/control.zig");
const frame = @import("cmux/frame.zig");
const Session = @import("cmux/Session.zig");

pub fn Cmux(comptime std: type, comptime time: type) type {
    const Allocator = std.mem.Allocator;
    const SessionType = Session.make(std, time);
    const ChannelConnType = ChannelConn.make(std, time);

    return struct {
        allocator: Allocator,
        options: Options,
        session: *SessionType,
        listener: NetListener,

        const Self = @This();

        pub const Role = control.Role;
        pub const Options = SessionType.Options;
        pub const InitError = SessionType.InitError || Allocator.Error;
        pub const DialError = SessionType.DialError || Allocator.Error;

        const ListenerImpl = struct {
            allocator: Allocator,
            parent: *Self,

            pub fn init(allocator: Allocator, parent: *Self) Allocator.Error!NetListener {
                const self = try allocator.create(@This());
                self.* = .{
                    .allocator = allocator,
                    .parent = parent,
                };
                return NetListener.init(self);
            }

            pub fn destroy(self: *@This()) void {
                self.allocator.destroy(self);
            }

            pub fn listen(self: *@This()) NetListener.ListenError!void {
                return self.parent.session.listen();
            }

            pub fn accept(self: *@This()) NetListener.AcceptError!NetConn {
                const channel = self.parent.session.acceptChannel() catch |err| return switch (err) {
                    error.Closed => error.Closed,
                    else => error.Unexpected,
                };
                const conn = ChannelConnType.init(self.parent.allocator, self.parent.session, channel) catch |err| {
                    self.parent.session.closeChannel(channel);
                    self.parent.session.releaseChannel(channel);
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                    };
                };
                self.parent.session.releaseChannel(channel);
                return conn;
            }

            pub fn close(self: *@This()) void {
                self.parent.close();
            }

            pub fn deinit(self: *@This()) void {
                self.destroy();
            }
        };

        pub fn init(allocator: Allocator, bearer: NetConn, options: Options) InitError!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const session = try SessionType.init(allocator, bearer, options);
            errdefer session.deinit();

            self.* = .{
                .allocator = allocator,
                .options = options,
                .session = session,
                .listener = undefined,
            };
            self.listener = try ListenerImpl.init(allocator, self);
            return self;
        }

        pub fn close(self: *Self) void {
            self.session.close();
        }

        pub fn deinit(self: *Self) void {
            self.listener.deinit();
            self.session.deinit();
            self.allocator.destroy(self);
        }

        pub fn dial(self: *Self, dlci: u16) DialError!NetConn {
            const channel = try self.session.dialChannel(dlci);
            return ChannelConnType.init(self.allocator, self.session, channel) catch |err| {
                self.session.closeChannel(channel);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                };
            };
        }
    };
}

pub fn TestRunner(comptime std: type, comptime time: type) @import("testing").TestRunner {
    const testing_api = @import("testing");
    const Tp = Cmux(std, time);
    const Thread = std.Thread;

    const TestCase = struct {
        const Pipe = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            closed: bool = false,
            data: std.ArrayList(u8) = .{},
        };

        const PairState = struct {
            allocator: std.mem.Allocator,
            mutex: Thread.Mutex = .{},
            refs: usize = 2,
            ab: Pipe = .{},
            ba: Pipe = .{},
        };

        const Endpoint = struct {
            allocator: std.mem.Allocator,
            pair: *PairState,
            inbound: *Pipe,
            outbound: *Pipe,
            closed: bool = false,
            read_deadline: ?time_mod.instant.Time = null,

            pub fn read(self: *@This(), buf: []u8) NetConn.ReadError!usize {
                if (self.closed) return error.EndOfStream;
                if (buf.len == 0) return 0;

                self.inbound.mutex.lock();
                defer self.inbound.mutex.unlock();

                while (self.inbound.data.items.len == 0 and !self.inbound.closed and !self.closed) {
                    if (self.read_deadline) |deadline| {
                        const remaining = @max(time_mod.instant.sub(deadline, time.instant.now()), 0);
                        if (remaining == 0) return error.TimedOut;
                        self.inbound.cond.timedWait(
                            &self.inbound.mutex,
                            @intCast(remaining),
                        ) catch return error.TimedOut;
                    } else {
                        self.inbound.cond.wait(&self.inbound.mutex);
                    }
                }

                if (self.closed) return error.EndOfStream;
                if (self.inbound.data.items.len == 0 and self.inbound.closed) return error.EndOfStream;

                const n = @min(buf.len, self.inbound.data.items.len);
                @memcpy(buf[0..n], self.inbound.data.items[0..n]);
                if (n == self.inbound.data.items.len) {
                    self.inbound.data.clearRetainingCapacity();
                } else {
                    std.mem.copyForwards(u8, self.inbound.data.items[0 .. self.inbound.data.items.len - n], self.inbound.data.items[n..self.inbound.data.items.len]);
                    self.inbound.data.items.len -= n;
                }
                return n;
            }

            pub fn write(self: *@This(), buf: []const u8) NetConn.WriteError!usize {
                if (self.closed) return error.BrokenPipe;
                self.outbound.mutex.lock();
                defer self.outbound.mutex.unlock();
                if (self.outbound.closed) return error.BrokenPipe;
                self.outbound.data.appendSlice(self.allocator, buf) catch return error.Unexpected;
                self.outbound.cond.broadcast();
                return buf.len;
            }

            pub fn close(self: *@This()) void {
                if (self.closed) return;
                self.closed = true;

                self.outbound.mutex.lock();
                self.outbound.closed = true;
                self.outbound.cond.broadcast();
                self.outbound.mutex.unlock();

                self.inbound.mutex.lock();
                self.inbound.cond.broadcast();
                self.inbound.mutex.unlock();
            }

            pub fn deinit(self: *@This()) void {
                self.close();
                self.pair.mutex.lock();
                std.debug.assert(self.pair.refs > 0);
                self.pair.refs -= 1;
                const refs = self.pair.refs;
                self.pair.mutex.unlock();
                if (refs == 0) {
                    self.pair.ab.data.deinit(self.allocator);
                    self.pair.ba.data.deinit(self.allocator);
                    self.allocator.destroy(self.pair);
                }
                self.allocator.destroy(self);
            }

            pub fn setReadDeadline(self: *@This(), deadline: ?time_mod.instant.Time) void {
                self.read_deadline = deadline;
            }

            pub fn setWriteDeadline(self: *@This(), deadline: ?time_mod.instant.Time) void {
                _ = self;
                _ = deadline;
            }
        };

        fn makePair(allocator: std.mem.Allocator) !struct { a: NetConn, b: NetConn } {
            const pair = try allocator.create(PairState);
            errdefer allocator.destroy(pair);
            pair.* = .{
                .allocator = allocator,
            };

            const a = try allocator.create(Endpoint);
            errdefer allocator.destroy(a);
            a.* = .{
                .allocator = allocator,
                .pair = pair,
                .inbound = &pair.ba,
                .outbound = &pair.ab,
            };

            const b = try allocator.create(Endpoint);
            errdefer b.deinit();
            b.* = .{
                .allocator = allocator,
                .pair = pair,
                .inbound = &pair.ab,
                .outbound = &pair.ba,
            };

            return .{
                .a = NetConn.init(a),
                .b = NetConn.init(b),
            };
        }

        fn dialRejectsZero(allocator: std.mem.Allocator) !void {
            const pair = try makePair(allocator);

            const responder = try Tp.init(allocator, pair.b, .{ .role = .responder });
            defer responder.deinit();
            const initiator = try Tp.init(allocator, pair.a, .{ .role = .initiator });
            defer initiator.deinit();

            try std.testing.expectError(error.InvalidDLCI, initiator.dial(0));
        }

        fn initRejectsInvalidOptions(allocator: std.mem.Allocator) !void {
            {
                const pair = try makePair(allocator);
                defer pair.a.deinit();
                defer pair.b.deinit();
                try std.testing.expectError(error.InvalidOptions, Tp.init(allocator, pair.a, .{
                    .role = .initiator,
                    .read_buffer_size = 0,
                }));
            }

            {
                const pair = try makePair(allocator);
                defer pair.a.deinit();
                defer pair.b.deinit();
                try std.testing.expectError(error.InvalidOptions, Tp.init(allocator, pair.a, .{
                    .role = .initiator,
                    .write_buffer_size = 0,
                }));
            }

            {
                const pair = try makePair(allocator);
                defer pair.a.deinit();
                defer pair.b.deinit();
                try std.testing.expectError(error.InvalidOptions, Tp.init(allocator, pair.a, .{
                    .role = .initiator,
                    .max_accept_queue = 0,
                }));
            }
        }

        fn dialTransfersData(allocator: std.mem.Allocator) !void {
            const pair = try makePair(allocator);

            const responder = try Tp.init(allocator, pair.b, .{ .role = .responder });
            defer responder.deinit();
            const initiator = try Tp.init(allocator, pair.a, .{ .role = .initiator });
            defer initiator.deinit();

            try responder.listener.listen();

            var local = try initiator.dial(5);
            defer local.deinit();
            var remote = try responder.listener.accept();
            defer remote.deinit();

            _ = try local.write("ping");
            var buf: [16]u8 = undefined;
            const n = try remote.read(&buf);
            try std.testing.expectEqualStrings("ping", buf[0..n]);

            _ = try remote.write("pong");
            const m = try local.read(&buf);
            try std.testing.expectEqualStrings("pong", buf[0..m]);
        }

        fn closeReleasesBlockedAccept(allocator: std.mem.Allocator) !void {
            const pair = try makePair(allocator);

            const responder = try Tp.init(allocator, pair.b, .{ .role = .responder });
            defer responder.deinit();
            const initiator = try Tp.init(allocator, pair.a, .{ .role = .initiator });
            defer initiator.deinit();

            const Result = struct {
                closed: bool = false,
                unexpected: bool = false,
            };
            var result = Result{};
            const worker = try Thread.spawn(.{}, struct {
                fn run(cmux: *Tp, res: *Result) void {
                    _ = cmux.listener.accept() catch |err| {
                        res.closed = err == error.Closed;
                        return;
                    };
                    res.unexpected = true;
                }
            }.run, .{ responder, &result });

            responder.close();
            worker.join();
            try std.testing.expect(result.closed);
            try std.testing.expect(!result.unexpected);
        }

        fn closeReleasesBlockedRead(allocator: std.mem.Allocator) !void {
            const pair = try makePair(allocator);

            const responder = try Tp.init(allocator, pair.b, .{ .role = .responder });
            defer responder.deinit();
            const initiator = try Tp.init(allocator, pair.a, .{ .role = .initiator });
            defer initiator.deinit();

            var local = try initiator.dial(9);
            defer local.deinit();
            var remote = try responder.listener.accept();
            defer remote.deinit();

            const Result = struct {
                eof: bool = false,
                unexpected: bool = false,
            };
            var result = Result{};
            const worker = try Thread.spawn(.{}, struct {
                fn run(conn: *NetConn, res: *Result) void {
                    var buf: [8]u8 = undefined;
                    _ = conn.read(&buf) catch |err| {
                        res.eof = err == error.EndOfStream;
                        return;
                    };
                    res.unexpected = true;
                }
            }.run, .{ &remote, &result });

            initiator.close();
            worker.join();
            try std.testing.expect(result.eof);
            try std.testing.expect(!result.unexpected);
        }

        fn rejectsWhenAcceptQueueIsFull(allocator: std.mem.Allocator) !void {
            const pair = try makePair(allocator);

            const responder = try Tp.init(allocator, pair.b, .{
                .role = .responder,
                .max_accept_queue = 1,
            });
            defer responder.deinit();
            const initiator = try Tp.init(allocator, pair.a, .{ .role = .initiator });
            defer initiator.deinit();

            try responder.listener.listen();

            var first = try initiator.dial(5);
            defer first.deinit();

            try std.testing.expectError(error.Rejected, initiator.dial(7));
        }

        fn invalidCrClosesBlockedAccept(allocator: std.mem.Allocator) !void {
            const pair = try makePair(allocator);
            defer pair.a.deinit();

            const responder = try Tp.init(allocator, pair.b, .{ .role = .responder });
            defer responder.deinit();
            try responder.listener.listen();

            const Result = struct {
                closed: bool = false,
                unexpected: bool = false,
            };
            var result = Result{};
            const worker = try Thread.spawn(.{}, struct {
                fn run(cmux: *Tp, res: *Result) void {
                    _ = cmux.listener.accept() catch |err| {
                        res.closed = err == error.Closed;
                        return;
                    };
                    res.unexpected = true;
                }
            }.run, .{ responder, &result });

            var encoded_buf: [16]u8 = undefined;
            const encoded = try @import("cmux/frame.zig").encode(&encoded_buf, .{
                .dlci = 0,
                .cr = control.responseCr(.initiator),
                .pf = true,
                .frame_type = .sabm,
            });
            _ = try pair.a.write(encoded);

            worker.join();
            try std.testing.expect(result.closed);
            try std.testing.expect(!result.unexpected);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.run("frame", frame.TestRunner(std));
            t.run("dialRejectsZero", testing_api.TestRunner.fromFn(std, 256 * 1024, struct {
                fn run(_: *testing_api.T, case_allocator: std.mem.Allocator) !void {
                    try TestCase.dialRejectsZero(case_allocator);
                }
            }.run));
            t.run("initRejectsInvalidOptions", testing_api.TestRunner.fromFn(std, 256 * 1024, struct {
                fn run(_: *testing_api.T, case_allocator: std.mem.Allocator) !void {
                    try TestCase.initRejectsInvalidOptions(case_allocator);
                }
            }.run));
            t.run("dialTransfersData", testing_api.TestRunner.fromFn(std, 256 * 1024, struct {
                fn run(_: *testing_api.T, case_allocator: std.mem.Allocator) !void {
                    try TestCase.dialTransfersData(case_allocator);
                }
            }.run));
            t.run("closeReleasesBlockedAccept", testing_api.TestRunner.fromFn(std, 256 * 1024, struct {
                fn run(_: *testing_api.T, case_allocator: std.mem.Allocator) !void {
                    try TestCase.closeReleasesBlockedAccept(case_allocator);
                }
            }.run));
            t.run("closeReleasesBlockedRead", testing_api.TestRunner.fromFn(std, 256 * 1024, struct {
                fn run(_: *testing_api.T, case_allocator: std.mem.Allocator) !void {
                    try TestCase.closeReleasesBlockedRead(case_allocator);
                }
            }.run));
            t.run("rejectsWhenAcceptQueueIsFull", testing_api.TestRunner.fromFn(std, 256 * 1024, struct {
                fn run(_: *testing_api.T, case_allocator: std.mem.Allocator) !void {
                    try TestCase.rejectsWhenAcceptQueueIsFull(case_allocator);
                }
            }.run));
            t.run("invalidCrClosesBlockedAccept", testing_api.TestRunner.fromFn(std, 256 * 1024, struct {
                fn run(_: *testing_api.T, case_allocator: std.mem.Allocator) !void {
                    try TestCase.invalidCrClosesBlockedAccept(case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
