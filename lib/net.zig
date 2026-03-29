//! net — Go-style networking for embed-zig.
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
pub const ntp = @import("net/ntp.zig");
pub const tls = @import("net/tls.zig");
pub const testing_mod = @import("testing");

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
        pub const TcpListener = TL;
        pub const UdpConn = UC;
        pub const Resolver = resolver_mod.Resolver(lib);
        pub const stack = @import("net/stack.zig");
        pub const http = @import("net/http.zig").make(lib);
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
    pub const fd_stream = @import("net/test_runner/fd_stream.zig");
    pub const fd_packet = @import("net/test_runner/fd_packet.zig");
    pub const tcp = @import("net/test_runner/tcp.zig");
    pub const udp = @import("net/test_runner/udp.zig");
    pub const tls = @import("net/test_runner/tls.zig");
    pub const tls_std_compat = @import("net/test_runner/tls_std_compat.zig");
    pub const tls_dial = @import("net/test_runner/tls_dial.zig");
    pub const resolver = @import("net/test_runner/resolver.zig");
    pub const resolver_dns = @import("net/test_runner/resolver_dns.zig");
    pub const ntp = @import("net/test_runner/ntp.zig");
    pub const http_transport = @import("net/test_runner/http_transport_local.zig");
    pub const http_transport_layer01 = @import("net/test_runner/http_transport_layer01.zig");
    pub const https_transport = @import("net/test_runner/https_transport.zig");
};

test "net/unit_tests" {
    _ = @import("net/fd.zig");
    _ = @import("net/test_runner/fd_packet.zig");
    _ = @import("net/stack/Stack.zig");
    _ = @import("net/http/Header.zig");
    _ = @import("net/http/ReadCloser.zig");
    _ = @import("net/http/Request.zig");
    _ = @import("net/http/Response.zig");
    _ = @import("net/http/status.zig");
    _ = @import("net/http/Transport.zig");
    _ = @import("net/ntp/wire.zig");
    _ = @import("net/tls/common.zig");
    _ = @import("net/tls/alert.zig");
    _ = @import("net/tls/extensions.zig");
    _ = @import("net/tls/kdf.zig");
    _ = @import("net/tls/record.zig");
    _ = @import("net/tls/client_handshake.zig");
    _ = @import("net/tls/server_handshake.zig");
    _ = @import("net/tls/Conn.zig");
    _ = @import("net/TcpListener.zig");
    _ = @import("net/url.zig");
}
