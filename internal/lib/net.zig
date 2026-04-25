//! net — Go-style networking for stdz-zig.
//!
//! Usage:
//!   const net = @import("net").make2(lib, impl);
//!   const Addr = net.netip.AddrPort;
//!
//!   // Quick dial (default options):
//!   var conn = try net.dial(allocator, .tcp, Addr.from4(.{127,0,0,1}, 80));
//!   defer conn.deinit();
//!
//!   // Configurable dialer (like Go's net.Dialer):
//!   var d = net.Dialer.init(allocator, .{});
//!   var conn = try d.dial(.tcp, Addr.from4(.{127,0,0,1}, 80));
//!   defer conn.deinit();
//!
//!   // Listen on IPv4:
//!   var ln = try net.listen(allocator, .{ .address = Addr.from4(.{0,0,0,0}, 8080) });
//!   defer ln.deinit();
//!
//!   // Listen on IPv6:
//!   var ln6 = try net.listen(allocator, .{ .address = Addr.init(net.netip.Addr.mustParse("::"), 8080) });

pub const Conn = @import("net/Conn.zig");
pub const Listener = @import("net/Listener.zig");
pub const PacketConn = @import("net/PacketConn.zig");
pub const runtime = @import("net/runtime.zig");
pub const netip = @import("net/netip.zig");
pub const url = @import("net/url.zig");
pub const http = @import("net/http.zig");
pub const textproto = @import("net/textproto.zig");
pub const Cmux = @import("net/Cmux.zig");
pub const ntp = @import("net/ntp.zig");
pub const tls = @import("net/tls.zig");
const tcp_conn = @import("net/TcpConn.zig");
const tcp_listener = @import("net/TcpListener.zig");
const dialer_mod = @import("net/Dialer.zig");
const udp_conn = @import("net/UdpConn.zig");
const resolver_mod = @import("net/Resolver.zig");
const unit_runner = @import("net/test_runner/unit.zig");
const integration_runner = @import("net/test_runner/integration.zig");

pub fn make2(comptime lib: type, comptime impl: type) type {
    const Allocator = lib.mem.Allocator;
    const Addr = netip.AddrPort;
    const IpAddr = netip.Addr;
    const RuntimeNs = runtime.make(impl);

    return struct {
        pub const Conn = @import("net/Conn.zig");
        pub const Listener = @import("net/Listener.zig");
        pub const PacketConn = @import("net/PacketConn.zig");
        pub const runtime = @import("net/runtime.zig");
        pub const netip = @import("net/netip.zig");
        pub const url = @import("net/url.zig");
        pub const Runtime = RuntimeNs;
        pub const Dialer = dialer_mod.Dialer(lib, @This());
        pub const TcpConn = tcp_conn.TcpConn(lib, @This());
        pub const TcpListener = tcp_listener.TcpListener(lib, @This());
        pub const UdpConn = udp_conn.UdpConn(lib, @This());
        pub const Resolver = resolver_mod.Resolver(lib, @This());
        pub const http = @import("net/http.zig").make(lib, @This());
        pub const textproto = @import("net/textproto.zig").make(lib);
        pub const Cmux = @import("net/Cmux.zig").Cmux(lib);
        pub const ntp = @import("net/ntp.zig").make(lib, @This());
        pub const tls = @import("net/tls.zig").make(lib, @This());
        pub const ListenOptions = TcpListener.Options;

        pub const ListenPacketOptions = struct {
            allocator: Allocator,
            address: Addr = Addr.from4(.{ 0, 0, 0, 0 }, 0),
            reuse_addr: bool = true,
        };

        pub const Network = Dialer.Network;

        pub fn addrDomain(addr: IpAddr) @import("net/runtime.zig").Domain {
            return @import("net/runtime.zig").addrDomain(addr);
        }

        pub fn dial(allocator: Allocator, network: Network, addr: Addr) !@import("net/Conn.zig") {
            const d = Dialer.init(allocator, .{});
            return d.dial(network, addr);
        }

        pub fn listen(allocator: Allocator, opts: ListenOptions) !@import("net/Listener.zig") {
            var ln = try TcpListener.init(allocator, opts);
            errdefer ln.deinit();
            try ln.listen();
            return ln;
        }

        pub fn listenPacket(opts: ListenPacketOptions) !@import("net/PacketConn.zig") {
            if (!opts.address.addr().isValid()) return error.InvalidAddress;
            var socket = try Runtime.udp(addrDomain(opts.address.addr()));
            errdefer teardownUdpSocket(&socket);
            if (opts.reuse_addr) {
                try socket.setOpt(.{ .socket = .{ .reuse_addr = true } });
            }
            try socket.bind(opts.address);
            return UdpConn.initPacketFromSocket(opts.allocator, socket);
        }

        fn teardownUdpSocket(socket: *Runtime.Udp) void {
            socket.close();
            socket.deinit();
        }
    };
}

fn testNet2(comptime lib: type, comptime runtime_impl: type) type {
    return make2(lib, runtime_impl.make(lib));
}

pub const test_runner = struct {
    pub const unit = struct {
        pub fn make2(comptime lib: type, comptime runtime_impl: type) @TypeOf(unit_runner.make(lib, testNet2(lib, runtime_impl))) {
            return unit_runner.make(lib, testNet2(lib, runtime_impl));
        }
    };

    pub const integration = struct {
        pub fn make2(comptime lib: type, comptime runtime_impl: type) @TypeOf(integration_runner.make(lib, testNet2(lib, runtime_impl))) {
            return integration_runner.make(lib, testNet2(lib, runtime_impl));
        }

        pub const runtime = struct {
            pub fn make2(comptime lib: type, comptime runtime_impl: type) @TypeOf(integration_runner.make2(lib, testNet2(lib, runtime_impl))) {
                return integration_runner.make2(lib, testNet2(lib, runtime_impl));
            }
        };
    };
};

pub fn TestRunner(comptime lib: type, comptime net: type) @import("testing").TestRunner {
    const testing_api = @import("testing");
    const http_mod = @import("net/http.zig");
    const tls_conn_mod = @import("net/tls/Conn.zig");
    const tls_listener_mod = @import("net/tls/Listener.zig");
    const tls_server_conn_mod = @import("net/tls/ServerConn.zig");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("make2_bindings", testing_api.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *testing_api.T, _: lib.mem.Allocator) !void {
                    try lib.testing.expect(net.Resolver == resolver_mod.Resolver(lib, net));
                    try lib.testing.expect(net.http.Transport == http_mod.Transport(lib, net));
                    try lib.testing.expect(net.tls.Conn == tls_conn_mod.Conn(lib, net));
                    try lib.testing.expect(net.tls.ServerConn == tls_server_conn_mod.ServerConn(lib, net));
                    try lib.testing.expect(net.tls.Listener == tls_listener_mod.Listener(lib, net));
                }
            }.run));
            t.run("listenPacket_reuse_addr_unsupported", testing_api.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *testing_api.T, test_allocator: lib.mem.Allocator) !void {
                    const FakeNet = make2(lib, struct {
                        pub const Tcp = struct {
                            pub fn close(_: *@This()) void {}
                            pub fn deinit(_: *@This()) void {}
                            pub fn shutdown(_: *@This(), _: runtime.ShutdownHow) runtime.SocketError!void {}
                            pub fn signal(_: *@This(), _: runtime.SignalEvent) void {}
                            pub fn bind(_: *@This(), _: netip.AddrPort) runtime.SocketError!void {}
                            pub fn listen(_: *@This(), _: u31) runtime.SocketError!void {}
                            pub fn accept(_: *@This(), _: ?*netip.AddrPort) runtime.SocketError!@This() {
                                return error.Unexpected;
                            }
                            pub fn connect(_: *@This(), _: netip.AddrPort) runtime.SocketError!void {}
                            pub fn finishConnect(_: *@This()) runtime.SocketError!void {}
                            pub fn recv(_: *@This(), _: []u8) runtime.SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn send(_: *@This(), _: []const u8) runtime.SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn localAddr(_: *@This()) runtime.SocketError!netip.AddrPort {
                                return netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0);
                            }
                            pub fn remoteAddr(_: *@This()) runtime.SocketError!netip.AddrPort {
                                return error.NotConnected;
                            }
                            pub fn setOpt(_: *@This(), _: runtime.TcpOption) runtime.SetSockOptError!void {}
                            pub fn poll(_: *@This(), _: runtime.PollEvents, _: ?u32) runtime.PollError!runtime.PollEvents {
                                return error.Unexpected;
                            }
                        };

                        pub const Udp = struct {
                            pub fn close(_: *@This()) void {}
                            pub fn deinit(_: *@This()) void {}
                            pub fn signal(_: *@This(), _: runtime.SignalEvent) void {}
                            pub fn bind(_: *@This(), _: netip.AddrPort) runtime.SocketError!void {}
                            pub fn connect(_: *@This(), _: netip.AddrPort) runtime.SocketError!void {}
                            pub fn finishConnect(_: *@This()) runtime.SocketError!void {}
                            pub fn recv(_: *@This(), _: []u8) runtime.SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn recvFrom(_: *@This(), _: []u8, _: ?*netip.AddrPort) runtime.SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn send(_: *@This(), _: []const u8) runtime.SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn sendTo(_: *@This(), _: []const u8, _: netip.AddrPort) runtime.SocketError!usize {
                                return error.Unexpected;
                            }
                            pub fn localAddr(_: *@This()) runtime.SocketError!netip.AddrPort {
                                return netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0);
                            }
                            pub fn remoteAddr(_: *@This()) runtime.SocketError!netip.AddrPort {
                                return error.NotConnected;
                            }
                            pub fn setOpt(_: *@This(), _: runtime.UdpOption) runtime.SetSockOptError!void {
                                return error.Unsupported;
                            }
                            pub fn poll(_: *@This(), _: runtime.PollEvents, _: ?u32) runtime.PollError!runtime.PollEvents {
                                return error.Unexpected;
                            }
                        };

                        pub fn tcp(_: runtime.Domain) runtime.CreateError!Tcp {
                            return .{};
                        }

                        pub fn udp(_: runtime.Domain) runtime.CreateError!Udp {
                            return .{};
                        }
                    });

                    try lib.testing.expectError(error.Unsupported, FakeNet.listenPacket(.{
                        .allocator = test_allocator,
                        .address = netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0),
                    }));
                }
            }.run));
            t.run("TcpListener", tcp_listener.TestRunner(lib, net));
            return t.wait();
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
