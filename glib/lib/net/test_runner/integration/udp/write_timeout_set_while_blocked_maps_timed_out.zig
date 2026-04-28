const stdz = @import("stdz");
const testing_api = @import("testing");
const Conn = @import("../../../Conn.zig");
const PacketConn = @import("../../../PacketConn.zig");
const UdpConnMod = @import("../../../UdpConn.zig");
const netip = @import("../../../netip.zig");
const runtime_mod = @import("../../../runtime.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;

            const Body = struct {
                const ReadyCounter = struct {
                    mu: std.Thread.Mutex = .{},
                    cond: std.Thread.Condition = .{},
                    ready: usize = 0,
                    target: usize,

                    fn init(target: usize) ReadyCounter {
                        return .{ .target = target };
                    }

                    fn markReady(counter: *ReadyCounter) void {
                        counter.mu.lock();
                        counter.ready += 1;
                        counter.cond.broadcast();
                        counter.mu.unlock();
                    }

                    fn waitUntilReady(counter: *ReadyCounter) void {
                        counter.mu.lock();
                        defer counter.mu.unlock();
                        while (counter.ready < counter.target) {
                            counter.cond.wait(&counter.mu);
                        }
                    }
                };

                const State = struct {
                    mu: std.Thread.Mutex = .{},
                    closed: bool = false,
                    read_interrupt: bool = false,
                    write_interrupt: bool = false,
                    write_ready: bool = false,

                    fn signal(state: *State, ev: runtime_mod.SignalEvent) void {
                        state.mu.lock();
                        defer state.mu.unlock();
                        switch (ev) {
                            .read_interrupt => state.read_interrupt = true,
                            .write_interrupt => state.write_interrupt = true,
                        }
                    }

                    fn close(state: *State) void {
                        state.mu.lock();
                        defer state.mu.unlock();
                        state.closed = true;
                        state.read_interrupt = true;
                        state.write_interrupt = true;
                    }

                    fn takeWriteInterrupt(state: *State) bool {
                        state.mu.lock();
                        defer state.mu.unlock();
                        const pending = state.write_interrupt;
                        state.write_interrupt = false;
                        return pending;
                    }

                    fn setWriteReady(state: *State, ready: bool) void {
                        state.mu.lock();
                        defer state.mu.unlock();
                        state.write_ready = ready;
                    }

                    fn isWriteReady(state: *State) bool {
                        state.mu.lock();
                        defer state.mu.unlock();
                        return state.write_ready;
                    }

                    fn isClosed(state: *State) bool {
                        state.mu.lock();
                        defer state.mu.unlock();
                        return state.closed;
                    }
                };

                const FakeRuntime = struct {
                    pub const Udp = struct {
                        state: *State,

                        pub fn close(sock: *@This()) void {
                            sock.state.close();
                        }

                        pub fn deinit(sock: *@This()) void {
                            _ = sock;
                        }

                        pub fn signal(sock: *@This(), ev: runtime_mod.SignalEvent) void {
                            sock.state.signal(ev);
                        }

                        pub fn bind(sock: *@This(), ap: netip.AddrPort) runtime_mod.SocketError!void {
                            _ = sock;
                            _ = ap;
                        }

                        pub fn connect(sock: *@This(), ap: netip.AddrPort) runtime_mod.SocketError!void {
                            _ = sock;
                            _ = ap;
                        }

                        pub fn finishConnect(sock: *@This()) runtime_mod.SocketError!void {
                            _ = sock;
                        }

                        pub fn recv(sock: *@This(), buf: []u8) runtime_mod.SocketError!usize {
                            _ = sock;
                            _ = buf;
                            return error.WouldBlock;
                        }

                        pub fn recvFrom(sock: *@This(), buf: []u8, src: ?*netip.AddrPort) runtime_mod.SocketError!usize {
                            _ = sock;
                            _ = buf;
                            _ = src;
                            return error.WouldBlock;
                        }

                        pub fn send(sock: *@This(), buf: []const u8) runtime_mod.SocketError!usize {
                            if (sock.state.isWriteReady()) return buf.len;
                            return error.WouldBlock;
                        }

                        pub fn sendTo(sock: *@This(), buf: []const u8, dst: netip.AddrPort) runtime_mod.SocketError!usize {
                            _ = dst;
                            if (sock.state.isWriteReady()) return buf.len;
                            return error.WouldBlock;
                        }

                        pub fn localAddr(sock: *@This()) runtime_mod.SocketError!netip.AddrPort {
                            _ = sock;
                            return netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 1111);
                        }

                        pub fn remoteAddr(sock: *@This()) runtime_mod.SocketError!netip.AddrPort {
                            _ = sock;
                            return netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 2222);
                        }

                        pub fn setOpt(sock: *@This(), opt: runtime_mod.UdpOption) runtime_mod.SetSockOptError!void {
                            _ = sock;
                            _ = opt;
                        }

                        pub fn poll(sock: *@This(), want: runtime_mod.PollEvents, timeout: ?net.time.duration.Duration) runtime_mod.PollError!runtime_mod.PollEvents {
                            const started = net.time.instant.now();
                            while (true) {
                                if (sock.state.isClosed()) return error.Closed;
                                if (want.write and sock.state.isWriteReady()) {
                                    return .{ .write = true };
                                }
                                if (want.write_interrupt and sock.state.takeWriteInterrupt()) {
                                    return .{ .write_interrupt = true };
                                }
                                if (timeout) |duration| {
                                    const elapsed = @import("time").instant.sub(net.time.instant.now(), started);
                                    if (elapsed >= duration) return error.TimedOut;
                                }
                                std.Thread.sleep(@intCast(net.time.duration.MilliSecond));
                            }
                        }
                    };
                };

                const FakeNet = struct {
                    pub const time = net.time;
                    pub const Runtime = FakeRuntime;
                };

                const FakeUdpConn = UdpConnMod.UdpConn(std, FakeNet);

                fn waitUntilWriteWaiting(impl: *FakeUdpConn, comptime thread_lib: type) void {
                    while (true) {
                        impl.write_mu.lock();
                        const waiting = impl.write_waiting;
                        impl.write_mu.unlock();
                        if (waiting) return;
                        thread_lib.Thread.sleep(@intCast(net.time.duration.MilliSecond));
                    }
                }

                const ConnWriteCtx = struct {
                    ready: *ReadyCounter,
                    conn: Conn,
                    bytes_written: ?usize = null,
                    err: ?anyerror = null,
                };

                const PacketWriteCtx = struct {
                    ready: *ReadyCounter,
                    conn: PacketConn,
                    bytes_written: ?usize = null,
                    err: ?anyerror = null,
                };

                const Worker = struct {
                    fn writeConn(ctx: *ConnWriteCtx) void {
                        ctx.ready.markReady();
                        ctx.bytes_written = ctx.conn.write("blocked") catch |err| {
                            ctx.err = err;
                            return;
                        };
                    }

                    fn writePacket(ctx: *PacketWriteCtx) void {
                        ctx.ready.markReady();
                        ctx.bytes_written = ctx.conn.writeTo("blocked", netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 3333)) catch |err| {
                            ctx.err = err;
                            return;
                        };
                    }

                    fn closeConnLater(conn: Conn, comptime thread_lib: type) void {
                        thread_lib.Thread.sleep(@intCast(200 * net.time.duration.MilliSecond));
                        conn.close();
                    }

                    fn closePacketLater(conn: PacketConn, comptime thread_lib: type) void {
                        thread_lib.Thread.sleep(@intCast(200 * net.time.duration.MilliSecond));
                        conn.close();
                    }
                };

                fn runConnCase(a: std.mem.Allocator) !void {
                    var state = State{};
                    var conn = try FakeUdpConn.initFromSocket(a, .{ .state = &state });
                    defer conn.deinit();
                    const conn_impl = try conn.as(FakeUdpConn);

                    var ready = ReadyCounter.init(1);
                    var write_ctx = ConnWriteCtx{
                        .ready = &ready,
                        .conn = conn,
                    };
                    var write_thread = try std.Thread.spawn(.{}, Worker.writeConn, .{&write_ctx});
                    var close_thread = try std.Thread.spawn(.{}, Worker.closeConnLater, .{ conn, std });

                    ready.waitUntilReady();
                    waitUntilWriteWaiting(conn_impl, std);
                    conn.setWriteDeadline(net.time.instant.add(net.time.instant.now(), 30 * net.time.duration.MilliSecond));

                    write_thread.join();
                    close_thread.join();

                    try std.testing.expect(write_ctx.err != null);
                    try std.testing.expect(write_ctx.err.? == error.TimedOut);
                    try std.testing.expectEqual(@as(?usize, null), write_ctx.bytes_written);
                }

                fn runPacketCase(a: std.mem.Allocator) !void {
                    var state = State{};
                    var conn = try FakeUdpConn.initPacketFromSocket(a, .{ .state = &state });
                    defer conn.deinit();
                    const conn_impl = try conn.as(FakeUdpConn);

                    var ready = ReadyCounter.init(1);
                    var write_ctx = PacketWriteCtx{
                        .ready = &ready,
                        .conn = conn,
                    };
                    var write_thread = try std.Thread.spawn(.{}, Worker.writePacket, .{&write_ctx});
                    var close_thread = try std.Thread.spawn(.{}, Worker.closePacketLater, .{ conn, std });

                    ready.waitUntilReady();
                    waitUntilWriteWaiting(conn_impl, std);
                    conn.setWriteDeadline(net.time.instant.add(net.time.instant.now(), 30 * net.time.duration.MilliSecond));

                    write_thread.join();
                    close_thread.join();

                    try std.testing.expect(write_ctx.err != null);
                    try std.testing.expect(write_ctx.err.? == error.TimedOut);
                    try std.testing.expectEqual(@as(?usize, null), write_ctx.bytes_written);
                }

                fn runConnClearCase(a: std.mem.Allocator) !void {
                    var state = State{};
                    var conn = try FakeUdpConn.initFromSocket(a, .{ .state = &state });
                    defer conn.deinit();
                    const conn_impl = try conn.as(FakeUdpConn);

                    conn.setWriteDeadline(net.time.instant.add(net.time.instant.now(), 30 * net.time.duration.MilliSecond));

                    var ready = ReadyCounter.init(1);
                    var write_ctx = ConnWriteCtx{
                        .ready = &ready,
                        .conn = conn,
                    };
                    var write_thread = try std.Thread.spawn(.{}, Worker.writeConn, .{&write_ctx});
                    var close_thread = try std.Thread.spawn(.{}, Worker.closeConnLater, .{ conn, std });

                    ready.waitUntilReady();
                    waitUntilWriteWaiting(conn_impl, std);
                    conn.setWriteDeadline(null);
                    std.Thread.sleep(@intCast(50 * net.time.duration.MilliSecond));
                    state.setWriteReady(true);

                    write_thread.join();
                    close_thread.join();

                    if (write_ctx.err) |err| return err;
                    try std.testing.expectEqual(@as(?usize, "blocked".len), write_ctx.bytes_written);
                }

                fn runPacketClearCase(a: std.mem.Allocator) !void {
                    var state = State{};
                    var conn = try FakeUdpConn.initPacketFromSocket(a, .{ .state = &state });
                    defer conn.deinit();
                    const conn_impl = try conn.as(FakeUdpConn);

                    conn.setWriteDeadline(net.time.instant.add(net.time.instant.now(), 30 * net.time.duration.MilliSecond));

                    var ready = ReadyCounter.init(1);
                    var write_ctx = PacketWriteCtx{
                        .ready = &ready,
                        .conn = conn,
                    };
                    var write_thread = try std.Thread.spawn(.{}, Worker.writePacket, .{&write_ctx});
                    var close_thread = try std.Thread.spawn(.{}, Worker.closePacketLater, .{ conn, std });

                    ready.waitUntilReady();
                    waitUntilWriteWaiting(conn_impl, std);
                    conn.setWriteDeadline(null);
                    std.Thread.sleep(@intCast(50 * net.time.duration.MilliSecond));
                    state.setWriteReady(true);

                    write_thread.join();
                    close_thread.join();

                    if (write_ctx.err) |err| return err;
                    try std.testing.expectEqual(@as(?usize, "blocked".len), write_ctx.bytes_written);
                }

                fn call(a: std.mem.Allocator) !void {
                    try runConnCase(a);
                    try runPacketCase(a);
                    try runConnClearCase(a);
                    try runPacketClearCase(a);
                }
            };

            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
