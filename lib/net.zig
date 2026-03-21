//! net — Go-style networking for embed-zig.
//!
//! Usage:
//!   const net = @import("net").Make(lib);
//!   const Addr = lib.net.Address;
//!
//!   // Quick dial (default options):
//!   var conn = try net.dial(allocator, .tcp, Addr.initIp4(.{127,0,0,1}, 80));
//!   defer conn.deinit();
//!
//!   // Configurable dialer (like Go's net.Dialer):
//!   var d = net.Dialer.init(allocator, .{});
//!   var conn = try d.dial(.tcp, Addr.initIp4(.{127,0,0,1}, 80));
//!   defer conn.deinit();
//!
//!   // Listen on IPv4:
//!   var ln = try net.listen(allocator, .{ .address = Addr.initIp4(.{0,0,0,0}, 8080) });
//!
//!   // Listen on IPv6:
//!   var ln6 = try net.listen(allocator, .{ .address = Addr.initIp6(.{0}**16, 8080, 0, 0) });

pub const Conn = @import("net/Conn.zig");
pub const Listener = @import("net/Listener.zig");
pub const PacketConn = @import("net/PacketConn.zig");
pub const url = @import("net/url.zig");

const tcp_conn = @import("net/TcpConn.zig");
const tcp_listener = @import("net/TcpListener.zig");
const dialer_mod = @import("net/Dialer.zig");
const udp_conn = @import("net/UdpConn.zig");
const resolver_mod = @import("net/Resolver.zig");

pub fn Make(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Addr = lib.net.Address;
    const TL = tcp_listener.TcpListener(lib);

    const UC = udp_conn.UdpConn(lib);

    return struct {
        pub const Dialer = dialer_mod.Dialer(lib);
        pub const TcpListener = TL;
        pub const UdpConn = UC;
        pub const Resolver = resolver_mod.Resolver(lib);
        pub const ListenOptions = TL.Options;

        pub const ListenPacketOptions = struct {
            allocator: Allocator,
            address: Addr = Addr.initIp4(.{ 0, 0, 0, 0 }, 0),
            reuse_addr: bool = true,
        };

        pub const Network = Dialer.Network;

        pub fn dial(allocator: Allocator, network: Network, addr: Addr) !Conn {
            const d = Dialer.init(allocator, .{});
            return d.dial(network, addr);
        }

        pub fn listen(allocator: Allocator, opts: ListenOptions) !TL {
            return TL.init(allocator, opts);
        }

        pub fn listenPacket(opts: ListenPacketOptions) !PacketConn {
            const posix = lib.posix;
            const fd = try posix.socket(opts.address.any.family, posix.SOCK.DGRAM, 0);
            errdefer posix.close(fd);

            if (opts.reuse_addr) {
                const enable: [4]u8 = @bitCast(@as(i32, 1));
                posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable) catch {};
            }

            try posix.bind(fd, @ptrCast(&opts.address.any), opts.address.getOsSockLen());
            return UC.initPacket(opts.allocator, fd);
        }
    };
}

pub const test_runner = struct {
    pub const tcp = @import("net/test_runner/tcp.zig");
    pub const udp = @import("net/test_runner/udp.zig");
    pub const resolver_fake = @import("net/test_runner/resolver_fake.zig");
    pub const resolver_ali_dns = @import("net/test_runner/resolver_ali_dns.zig");
};

test {
    _ = @import("net/Conn.zig");
    _ = @import("net/Listener.zig");
    _ = @import("net/PacketConn.zig");
    _ = @import("net/TcpConn.zig");
    _ = @import("net/TcpListener.zig");
    _ = @import("net/Dialer.zig");
    _ = @import("net/UdpConn.zig");
    _ = @import("net/Resolver.zig");
    _ = @import("net/url.zig");
    _ = @import("net/test_runner/tcp.zig");
    _ = @import("net/test_runner/udp.zig");
    _ = @import("net/test_runner/resolver_fake.zig");
    _ = @import("net/test_runner/resolver_ali_dns.zig");
}
