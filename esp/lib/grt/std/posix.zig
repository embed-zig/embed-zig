//! Temporary POSIX placeholder for the current glib stdz contract.
//!
//! GRT does not implement POSIX. Keep this namespace only while glib.runtime
//! still requires a `stdz_impl.posix` shape; callers should use the net runtime
//! instead of socket-style POSIX APIs.

pub const fd_t = i32;
pub const socket_t = i32;
pub const socklen_t = u32;
pub const mode_t = u32;

pub const timeval = extern struct {
    tv_sec: i64 = 0,
    tv_usec: i64 = 0,
};

pub const timespec = extern struct {
    tv_sec: i64 = 0,
    tv_nsec: c_long = 0,
};

pub const pollfd = extern struct {
    fd: fd_t,
    events: i16,
    revents: i16,
};

pub const sockaddr = extern struct {
    len: u8 = @sizeOf(@This()),
    family: u8 = 0,
    data: [14]u8 = [_]u8{0} ** 14,

    pub const storage = extern struct {
        len: u8 = @sizeOf(@This()),
        family: u8 = 0,
        _padding0: u16 = 0,
        _padding1: u32 = 0,
        data: [20]u8 = [_]u8{0} ** 20,
    };

    pub const in = extern struct {
        len: u8 = @sizeOf(@This()),
        family: u8 = 2,
        port: u16 = 0,
        addr: u32 = 0,
        zero: [8]u8 = [_]u8{0} ** 8,
    };

    pub const in6 = extern struct {
        len: u8 = @sizeOf(@This()),
        family: u8 = 10,
        port: u16 = 0,
        flowinfo: u32 = 0,
        addr: [16]u8 = [_]u8{0} ** 16,
        scope_id: u32 = 0,
    };
};

pub const AF = struct {
    pub const UNSPEC: u32 = 0;
    pub const INET: u32 = 2;
    pub const INET6: u32 = 10;
};

pub const SOCK = struct {
    pub const STREAM: u32 = 1;
    pub const DGRAM: u32 = 2;
    pub const RAW: u32 = 3;
    pub const NONBLOCK: u32 = 0x4000;
    pub const CLOEXEC: u32 = 0x80000;
};

pub const IPPROTO = struct {
    pub const IP: u32 = 0;
    pub const TCP: u32 = 6;
    pub const UDP: u32 = 17;
    pub const IPV6: u32 = 41;
};

pub const SOL = struct {
    pub const SOCKET: c_int = 0xfff;
};

pub const SO = struct {
    pub const TYPE: u32 = 0x1008;
};

pub const POLL = struct {
    pub const IN: i16 = 0x001;
    pub const OUT: i16 = 0x004;
    pub const ERR: i16 = 0x008;
};

pub const E = enum(c_int) {
    ACCES = 13,
    PERM = 1,
    ADDRINUSE = 98,
    ADDRNOTAVAIL = 99,
    AFNOSUPPORT = 97,
    CONNREFUSED = 111,
    CONNRESET = 104,
    HOSTUNREACH = 118,
    NETUNREACH = 101,
    TIMEDOUT = 116,
    NOENT = 2,
};

pub const F = struct {
    pub const GETFL: i32 = 3;
    pub const SETFL: i32 = 4;
};

pub const O = packed struct(u32) {
    NONBLOCK: bool = false,
    _padding: u31 = 0,
};

pub fn socket(domain: u32, socket_type: u32, protocol: u32) @import("glib").std.posix.SocketError!socket_t {
    _ = domain;
    _ = socket_type;
    _ = protocol;
    unsupported();
}

pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) @import("glib").std.posix.BindError!void {
    _ = sock;
    _ = addr;
    _ = len;
    unsupported();
}

pub fn listen(sock: socket_t, backlog: u31) @import("glib").std.posix.ListenError!void {
    _ = sock;
    _ = backlog;
    unsupported();
}

pub fn accept(sock: socket_t, addr: ?*sockaddr, addrlen: ?*socklen_t, flags: u32) @import("glib").std.posix.AcceptError!socket_t {
    _ = sock;
    _ = addr;
    _ = addrlen;
    _ = flags;
    unsupported();
}

pub fn connect(sock: socket_t, addr: *const sockaddr, len: socklen_t) @import("glib").std.posix.ConnectError!void {
    _ = sock;
    _ = addr;
    _ = len;
    unsupported();
}

pub fn send(sock: socket_t, buf: []const u8, flags: u32) @import("glib").std.posix.SendError!usize {
    _ = sock;
    _ = buf;
    _ = flags;
    unsupported();
}

pub fn recv(sock: socket_t, buf: []u8, flags: u32) @import("glib").std.posix.RecvFromError!usize {
    _ = sock;
    _ = buf;
    _ = flags;
    unsupported();
}

pub fn sendto(sock: socket_t, buf: []const u8, flags: u32, dest_addr: ?*const sockaddr, addrlen: socklen_t) @import("glib").std.posix.SendToError!usize {
    _ = sock;
    _ = buf;
    _ = flags;
    _ = dest_addr;
    _ = addrlen;
    unsupported();
}

pub fn recvfrom(sock: socket_t, buf: []u8, flags: u32, src_addr: ?*sockaddr, addrlen: ?*socklen_t) @import("glib").std.posix.RecvFromError!usize {
    _ = sock;
    _ = buf;
    _ = flags;
    _ = src_addr;
    _ = addrlen;
    unsupported();
}

pub fn setsockopt(sock: socket_t, level: i32, optname: u32, opt: []const u8) @import("glib").std.posix.SetSockOptError!void {
    _ = sock;
    _ = level;
    _ = optname;
    _ = opt;
    unsupported();
}

pub fn shutdown(sock: socket_t, how: @import("glib").std.posix.ShutdownHow) @import("glib").std.posix.ShutdownError!void {
    _ = sock;
    _ = how;
    unsupported();
}

pub fn getsockname(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) @import("glib").std.posix.GetSockNameError!void {
    _ = sock;
    _ = addr;
    _ = addrlen;
    unsupported();
}

pub fn poll(fds: []pollfd, timeout: i32) @import("glib").std.posix.PollError!usize {
    _ = fds;
    _ = timeout;
    unsupported();
}

pub fn close(fd: fd_t) void {
    _ = fd;
}

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) @import("glib").std.posix.FcntlError!usize {
    _ = fd;
    _ = cmd;
    _ = arg;
    unsupported();
}

pub fn open(path: []const u8, flags: O, mode: mode_t) @import("glib").std.posix.OpenError!fd_t {
    _ = path;
    _ = flags;
    _ = mode;
    unsupported();
}

pub fn read(fd: fd_t, buf: []u8) @import("glib").std.posix.ReadError!usize {
    _ = fd;
    _ = buf;
    unsupported();
}

pub fn write(fd: fd_t, buf: []const u8) @import("glib").std.posix.WriteError!usize {
    _ = fd;
    _ = buf;
    unsupported();
}

pub fn lseek_SET(fd: fd_t, offset: u64) @import("glib").std.posix.SeekError!void {
    _ = fd;
    _ = offset;
    unsupported();
}

pub fn lseek_CUR(fd: fd_t, offset: i64) @import("glib").std.posix.SeekError!void {
    _ = fd;
    _ = offset;
    unsupported();
}

pub fn lseek_CUR_get(fd: fd_t) @import("glib").std.posix.SeekError!u64 {
    _ = fd;
    unsupported();
}

pub fn lseek_END(fd: fd_t, offset: i64) @import("glib").std.posix.SeekError!void {
    _ = fd;
    _ = offset;
    unsupported();
}

pub fn mkdir(path: []const u8, mode: mode_t) @import("glib").std.posix.MakeDirError!void {
    _ = path;
    _ = mode;
    unsupported();
}

pub fn unlink(path: []const u8) @import("glib").std.posix.UnlinkError!void {
    _ = path;
    unsupported();
}

fn unsupported() noreturn {
    @panic("grt.std.posix is a temporary unsupported placeholder");
}
