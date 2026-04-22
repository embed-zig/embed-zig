//! net — Go-style networking for stdz-zig.
//!
//! Usage:
//!   const net = @import("net").make(lib);
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
pub const netip = @import("net/netip.zig");
pub const stack = @import("net/stack.zig");
pub const url = @import("net/url.zig");
pub const http = @import("net/http.zig");
pub const textproto = @import("net/textproto.zig");
pub const Cmux = @import("net/Cmux.zig");
pub const ntp = @import("net/ntp.zig");
pub const tls = @import("net/tls.zig");
const tcp_conn = @import("net/TcpConn.zig");
const tcp_listener = @import("net/TcpListener.zig");
const dialer_mod = @import("net/Dialer.zig");
const fd_mod = @import("net/fd.zig");
const sockaddr_mod = @import("net/fd/SockAddr.zig");
const udp_conn = @import("net/UdpConn.zig");
const resolver_mod = @import("net/Resolver.zig");

pub fn make(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Addr = netip.AddrPort;
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const TL = tcp_listener.TcpListener(lib);

    const UC = udp_conn.UdpConn(lib);

    return struct {
        pub const Dialer = dialer_mod.Dialer(lib);
        pub const TcpConn = tcp_conn.TcpConn(lib);
        pub const TcpListener = TL;
        pub const UdpConn = UC;
        pub const Resolver = resolver_mod.Resolver(lib);
        pub const stack = @import("net/stack.zig");
        pub const http = @import("net/http.zig").make(lib);
        pub const textproto = @import("net/textproto.zig").make(lib);
        pub const Cmux = @import("net/Cmux.zig").Cmux(lib);
        pub const ntp = @import("net/ntp.zig").make(lib);
        pub const tls = @import("net/tls.zig").make(lib);
        pub const ListenOptions = TL.Options;

        pub const ListenPacketOptions = struct {
            allocator: Allocator,
            address: Addr = Addr.from4(.{ 0, 0, 0, 0 }, 0),
            reuse_addr: bool = true,
        };

        pub const Network = Dialer.Network;

        pub fn dial(allocator: Allocator, network: Network, addr: Addr) !Conn {
            const d = Dialer.init(allocator, .{});
            return d.dial(network, addr);
        }

        pub fn listen(allocator: Allocator, opts: ListenOptions) !Listener {
            var ln = try TL.init(allocator, opts);
            errdefer ln.deinit();
            try ln.listen();
            return ln;
        }

        pub fn listenPacket(opts: ListenPacketOptions) !PacketConn {
            const posix = lib.posix;
            const encoded = try SockAddr.encode(opts.address);
            const fd = try posix.socket(encoded.family, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd);

            if (opts.reuse_addr) {
                const enable: [4]u8 = @bitCast(@as(i32, 1));
                posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable) catch {};
            }

            try posix.bind(fd, @ptrCast(&encoded.storage), encoded.len);
            return UC.initPacket(opts.allocator, fd);
        }
    };
}

pub const test_runner = struct {
    pub const unit = @import("net/test_runner/unit.zig");
    pub const integration = @import("net/test_runner/integration.zig");
};
