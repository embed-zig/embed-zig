//! runtime — async TCP/UDP runtime contract for net.
//!
//! This layer stays below `net`'s public `TcpConn`, `UdpConn`, and
//! `TcpListener` wrappers. It exposes concrete runtime-managed `Tcp` and `Udp`
//! objects with:
//! - non-blocking socket operations
//! - per-socket directional interrupt events for runtime/backend/close wakeups,
//!   consumed once by `poll(...)`
//! - per-socket `poll(...)`
//! - explicit `close()` / `deinit()` lifecycle hooks
//!
//! It intentionally does not own:
//! - `Context`
//! - deadline policy
//! - public `net.Conn` / `net.PacketConn` / `net.Listener`

const runtime = @This();
const netip = @import("netip.zig");

pub const Domain = enum(u8) {
    inet,
    inet6,
};

pub fn addrDomain(addr: netip.Addr) Domain {
    return if (addr.is4()) .inet else .inet6;
}

pub const ShutdownHow = enum(u2) {
    read,
    write,
    both,
};

pub const PollEvents = packed struct(u6) {
    read: bool = false,
    write: bool = false,
    failed: bool = false,
    hup: bool = false,
    read_interrupt: bool = false,
    write_interrupt: bool = false,
};

pub const SignalEvent = enum(u2) {
    read_interrupt,
    write_interrupt,
};

pub const CreateError = error{
    Unsupported,
    SystemResources,
    OutOfMemory,
    Unexpected,
};

pub const SocketError = error{
    WouldBlock,
    Closed,
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    AlreadyConnected,
    ConnectionAborted,
    ConnectionPending,
    ConnectionRefused,
    ConnectionReset,
    BrokenPipe,
    MessageTooLong,
    NetworkUnreachable,
    NotConnected,
    TimedOut,
    Unexpected,
};

pub const SetSockOptError = error{
    Closed,
    Unsupported,
    Unexpected,
};

pub const PollError = error{
    Closed,
    TimedOut,
    Unexpected,
};

pub const SocketLevelOption = union(enum) {
    reuse_addr: bool,
    reuse_port: bool,
    broadcast: bool,
};

pub const TcpLevelOption = union(enum) {
    no_delay: bool,
};

pub const TcpOption = union(enum) {
    socket: SocketLevelOption,
    tcp: TcpLevelOption,
};

pub const UdpOption = union(enum) {
    socket: SocketLevelOption,
};

pub fn make(comptime Impl: type) type {
    return struct {
        pub const Tcp = Impl.Tcp;
        pub const Udp = Impl.Udp;

        comptime {
            _ = @as(type, Impl.Tcp);
            _ = @as(type, Impl.Udp);

            _ = @as(*const fn (runtime.Domain) runtime.CreateError!Tcp, &Impl.tcp);
            _ = @as(*const fn (runtime.Domain) runtime.CreateError!Udp, &Impl.udp);

            _ = @as(*const fn (*Tcp) void, &Tcp.close);
            _ = @as(*const fn (*Tcp) void, &Tcp.deinit);
            _ = @as(*const fn (*Tcp, runtime.ShutdownHow) runtime.SocketError!void, &Tcp.shutdown);
            _ = @as(*const fn (*Tcp, runtime.SignalEvent) void, &Tcp.signal);
            _ = @as(*const fn (*Tcp, netip.AddrPort) runtime.SocketError!void, &Tcp.bind);
            _ = @as(*const fn (*Tcp, u31) runtime.SocketError!void, &Tcp.listen);
            _ = @as(*const fn (*Tcp, ?*netip.AddrPort) runtime.SocketError!Tcp, &Tcp.accept);
            _ = @as(*const fn (*Tcp, netip.AddrPort) runtime.SocketError!void, &Tcp.connect);
            _ = @as(*const fn (*Tcp) runtime.SocketError!void, &Tcp.finishConnect);
            _ = @as(*const fn (*Tcp, []u8) runtime.SocketError!usize, &Tcp.recv);
            _ = @as(*const fn (*Tcp, []const u8) runtime.SocketError!usize, &Tcp.send);
            _ = @as(*const fn (*Tcp) runtime.SocketError!netip.AddrPort, &Tcp.localAddr);
            _ = @as(*const fn (*Tcp) runtime.SocketError!netip.AddrPort, &Tcp.remoteAddr);
            _ = @as(*const fn (*Tcp, runtime.TcpOption) runtime.SetSockOptError!void, &Tcp.setOpt);
            _ = @as(*const fn (*Tcp, runtime.PollEvents, ?u32) runtime.PollError!runtime.PollEvents, &Tcp.poll);

            _ = @as(*const fn (*Udp) void, &Udp.close);
            _ = @as(*const fn (*Udp) void, &Udp.deinit);
            _ = @as(*const fn (*Udp, runtime.SignalEvent) void, &Udp.signal);
            _ = @as(*const fn (*Udp, netip.AddrPort) runtime.SocketError!void, &Udp.bind);
            _ = @as(*const fn (*Udp, netip.AddrPort) runtime.SocketError!void, &Udp.connect);
            _ = @as(*const fn (*Udp) runtime.SocketError!void, &Udp.finishConnect);
            _ = @as(*const fn (*Udp, []u8) runtime.SocketError!usize, &Udp.recv);
            _ = @as(*const fn (*Udp, []u8, ?*netip.AddrPort) runtime.SocketError!usize, &Udp.recvFrom);
            _ = @as(*const fn (*Udp, []const u8) runtime.SocketError!usize, &Udp.send);
            _ = @as(*const fn (*Udp, []const u8, netip.AddrPort) runtime.SocketError!usize, &Udp.sendTo);
            _ = @as(*const fn (*Udp) runtime.SocketError!netip.AddrPort, &Udp.localAddr);
            _ = @as(*const fn (*Udp) runtime.SocketError!netip.AddrPort, &Udp.remoteAddr);
            _ = @as(*const fn (*Udp, runtime.UdpOption) runtime.SetSockOptError!void, &Udp.setOpt);
            _ = @as(*const fn (*Udp, runtime.PollEvents, ?u32) runtime.PollError!runtime.PollEvents, &Udp.poll);
        }

        pub fn tcp(domain: runtime.Domain) runtime.CreateError!Tcp {
            return Impl.tcp(domain);
        }

        pub fn udp(domain: runtime.Domain) runtime.CreateError!Udp {
            return Impl.udp(domain);
        }
    };
}
