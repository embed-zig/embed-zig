//! TcpListener — binds a TCP port and starts listening on demand.
//!
//! `init()` binds but does not call `listen()`. Callers can invoke `listen()`
//! directly, or use `net.listen(...)` / `net.tls.listen(...)` for a one-shot
//! bind+listen convenience.

const Conn = @import("Conn.zig");
const Listener = @import("Listener.zig");
const tcp_conn = @import("TcpConn.zig");

pub fn TcpListener(comptime std: type, comptime net: type) type {
    const AddrPort = @import("netip/AddrPort.zig");
    const Allocator = std.mem.Allocator;
    const Mutex = std.Thread.Mutex;
    const Runtime = net.Runtime;
    const RuntimeTcp = Runtime.Tcp;
    const SC = tcp_conn.TcpConn(std, net);

    return struct {
        socket: RuntimeTcp,
        allocator: Allocator,
        backlog: u31,
        state_mu: Mutex = .{},
        closed: bool = false,
        listening: bool = false,
        accept_waiting: bool = false,

        const Self = @This();

        pub const Options = struct {
            address: AddrPort = AddrPort.from4(.{ 0, 0, 0, 0 }, 0),
            backlog: u31 = 128,
            reuse_addr: bool = true,
        };

        pub fn init(allocator: Allocator, opts: Options) !Listener {
            if (!opts.address.addr().isValid()) return error.InvalidAddress;
            var socket = try Runtime.tcp(net.addrDomain(opts.address.addr()));
            errdefer teardownSocket(&socket);

            if (opts.reuse_addr) {
                try socket.setOpt(.{ .socket = .{ .reuse_addr = true } });
            }
            try socket.bind(opts.address);

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .socket = socket,
                .allocator = allocator,
                .backlog = opts.backlog,
            };
            return Listener.init(self);
        }

        pub fn listen(self: *Self) Listener.ListenError!void {
            self.state_mu.lock();
            defer self.state_mu.unlock();

            if (self.closed) return error.Closed;
            if (self.listening) return;
            try self.socket.listen(self.backlog);
            self.listening = true;
        }

        pub fn accept(self: *Self) Listener.AcceptError!Conn {
            while (true) {
                try self.ensureAccepting();
                var remote_addr: AddrPort = undefined;
                const socket = self.socket.accept(&remote_addr) catch |err| switch (err) {
                    error.Closed => return error.Closed,
                    error.WouldBlock => {
                        try self.waitForAccept();
                        continue;
                    },
                    error.AccessDenied => return error.PermissionDenied,
                    error.ConnectionAborted => return error.ConnectionAborted,
                    error.ConnectionReset => return error.ConnectionResetByPeer,
                    else => return error.Unexpected,
                };
                var owned_socket = socket;
                errdefer teardownSocket(&owned_socket);
                if (self.isClosed()) return error.Closed;
                return SC.initFromSocket(self.allocator, owned_socket) catch |err| switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                };
            }
        }

        pub fn close(self: *Self) void {
            self.state_mu.lock();
            if (self.closed) {
                self.state_mu.unlock();
                return;
            }
            self.closed = true;
            self.listening = false;
            self.state_mu.unlock();
            self.socket.close();
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.socket.deinit();
            self.allocator.destroy(self);
        }

        pub const PortError = error{ Closed, Unexpected };

        pub fn port(self: *Self) PortError!u16 {
            if (self.isClosed()) return error.Closed;
            const addr = self.socket.localAddr() catch return error.Unexpected;
            return addr.port();
        }

        fn teardownSocket(socket: *RuntimeTcp) void {
            socket.close();
            socket.deinit();
        }

        fn isClosed(self: *Self) bool {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            return self.closed;
        }

        fn waitForAccept(self: *Self) Listener.AcceptError!void {
            const poll_result = blk: {
                self.state_mu.lock();
                if (self.closed) {
                    self.state_mu.unlock();
                    return error.Closed;
                }
                if (!self.listening) {
                    self.state_mu.unlock();
                    return error.SocketNotListening;
                }
                self.accept_waiting = true;
                self.state_mu.unlock();
                defer {
                    self.state_mu.lock();
                    self.accept_waiting = false;
                    self.state_mu.unlock();
                }
                break :blk self.socket.poll(.{
                    .read = true,
                    .failed = true,
                    .hup = true,
                    .read_interrupt = true,
                }, null);
            };

            _ = poll_result catch |err| switch (err) {
                error.Closed => return error.Closed,
                else => return error.Unexpected,
            };
        }

        fn ensureAccepting(self: *Self) Listener.AcceptError!void {
            self.state_mu.lock();
            defer self.state_mu.unlock();

            if (self.closed) return error.Closed;
            if (!self.listening) return error.SocketNotListening;
        }
    };
}

pub fn TestRunner(comptime std: type, comptime net: type) @import("testing").TestRunner {
    const testing_api = @import("testing");
    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: std.mem.Allocator) !void {
            const testing = std.testing;
            const Addr = @import("netip/AddrPort.zig");
            const TL = TcpListener(std, net);

            {
                var ln = try TL.init(allocator, .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
                defer ln.deinit();
                try ln.listen();
                ln.close();

                try testing.expectError(error.Closed, ln.accept());
            }

            {
                var ln = try TL.init(allocator, .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
                defer ln.deinit();

                try testing.expectError(error.SocketNotListening, ln.accept());
            }

            {
                const fake_net = struct {
                    pub const time = net.time;

                    pub const Runtime = struct {
                        pub const Tcp = struct {
                            pub fn close(_: *@This()) void {}
                            pub fn deinit(_: *@This()) void {}
                            pub fn shutdown(_: *@This(), _: @import("runtime.zig").ShutdownHow) @import("runtime.zig").SocketError!void {}
                            pub fn signal(_: *@This(), _: @import("runtime.zig").SignalEvent) void {}
                            pub fn bind(_: *@This(), _: @import("netip/AddrPort.zig")) @import("runtime.zig").SocketError!void {}
                            pub fn listen(_: *@This(), _: u31) @import("runtime.zig").SocketError!void {}
                            pub fn accept(_: *@This(), _: ?*@import("netip/AddrPort.zig")) @import("runtime.zig").SocketError!@This() {
                                return error.Unexpected;
                            }
                            pub fn connect(_: *@This(), _: @import("netip/AddrPort.zig")) @import("runtime.zig").SocketError!void {}
                            pub fn finishConnect(_: *@This()) @import("runtime.zig").SocketError!void {}
                            pub fn recv(_: *@This(), _: []u8) @import("runtime.zig").SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn send(_: *@This(), _: []const u8) @import("runtime.zig").SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn localAddr(_: *@This()) @import("runtime.zig").SocketError!@import("netip/AddrPort.zig") {
                                return Addr.from4(.{ 127, 0, 0, 1 }, 0);
                            }
                            pub fn remoteAddr(_: *@This()) @import("runtime.zig").SocketError!@import("netip/AddrPort.zig") {
                                return error.NotConnected;
                            }
                            pub fn setOpt(_: *@This(), _: @import("runtime.zig").TcpOption) @import("runtime.zig").SetSockOptError!void {
                                return error.Unsupported;
                            }
                            pub fn poll(_: *@This(), _: @import("runtime.zig").PollEvents, _: ?@import("time").duration.Duration) @import("runtime.zig").PollError!@import("runtime.zig").PollEvents {
                                return error.Unexpected;
                            }
                        };

                        pub const Udp = struct {
                            pub fn close(_: *@This()) void {}
                            pub fn deinit(_: *@This()) void {}
                            pub fn signal(_: *@This(), _: @import("runtime.zig").SignalEvent) void {}
                            pub fn bind(_: *@This(), _: @import("netip/AddrPort.zig")) @import("runtime.zig").SocketError!void {}
                            pub fn connect(_: *@This(), _: @import("netip/AddrPort.zig")) @import("runtime.zig").SocketError!void {}
                            pub fn finishConnect(_: *@This()) @import("runtime.zig").SocketError!void {}
                            pub fn recv(_: *@This(), _: []u8) @import("runtime.zig").SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn recvFrom(_: *@This(), _: []u8, _: ?*@import("netip/AddrPort.zig")) @import("runtime.zig").SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn send(_: *@This(), _: []const u8) @import("runtime.zig").SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn sendTo(_: *@This(), _: []const u8, _: @import("netip/AddrPort.zig")) @import("runtime.zig").SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn localAddr(_: *@This()) @import("runtime.zig").SocketError!@import("netip/AddrPort.zig") {
                                return Addr.from4(.{ 127, 0, 0, 1 }, 0);
                            }
                            pub fn remoteAddr(_: *@This()) @import("runtime.zig").SocketError!@import("netip/AddrPort.zig") {
                                return error.NotConnected;
                            }
                            pub fn setOpt(_: *@This(), _: @import("runtime.zig").UdpOption) @import("runtime.zig").SetSockOptError!void {
                                return error.Unsupported;
                            }
                            pub fn poll(_: *@This(), _: @import("runtime.zig").PollEvents, _: ?@import("time").duration.Duration) @import("runtime.zig").PollError!@import("runtime.zig").PollEvents {
                                return error.Unexpected;
                            }
                        };

                        pub fn tcp(_: @import("runtime.zig").Domain) @import("runtime.zig").CreateError!Tcp {
                            return .{};
                        }

                        pub fn udp(_: @import("runtime.zig").Domain) @import("runtime.zig").CreateError!Udp {
                            return .{};
                        }
                    };

                    pub fn addrDomain(addr: @import("netip/Addr.zig")) @import("runtime.zig").Domain {
                        return if (addr.is4()) .inet else .inet6;
                    }
                };
                const FakeListener = TcpListener(std, fake_net);

                try testing.expectError(error.Unsupported, FakeListener.init(allocator, .{
                    .address = Addr.from4(.{ 127, 0, 0, 1 }, 0),
                    .reuse_addr = true,
                }));
            }
        }
    }.run);
}
