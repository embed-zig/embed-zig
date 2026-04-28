//! net — Go-style networking for stdz-zig.
//!
//! Usage:
//!   const net = @import("net").make(std, time, impl);
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

pub fn make(comptime std: type, comptime time: type, comptime impl: type) type {
    return makeWithTime(std, time, impl);
}

fn makeWithTime(comptime std: type, comptime Time: type, comptime impl: type) type {
    const Allocator = std.mem.Allocator;
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
        pub const time = Time;
        pub const Runtime = RuntimeNs;
        pub const Dialer = dialer_mod.Dialer(std, @This());
        pub const TcpConn = tcp_conn.TcpConn(std, @This());
        pub const TcpListener = tcp_listener.TcpListener(std, @This());
        pub const UdpConn = udp_conn.UdpConn(std, @This());
        pub const Resolver = resolver_mod.Resolver(std, @This());
        pub const http = @import("net/http.zig").make(std, @This());
        pub const textproto = @import("net/textproto.zig").make(std);
        pub const Cmux = @import("net/Cmux.zig").Cmux(std, Time);
        pub const ntp = @import("net/ntp.zig").make(std, @This());
        pub const tls = @import("net/tls.zig").make(std, @This());
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

pub const test_runner = struct {
    pub const unit = @import("net/test_runner/unit.zig");
    pub const integration = @import("net/test_runner/integration.zig");
};
