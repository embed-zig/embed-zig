//! Std-backed posix impl.

const std = @import("std");
const glib = @import("glib");

const posix = std.posix;

pub const fd_t = posix.fd_t;
pub const socket_t = posix.socket_t;
pub const sockaddr = posix.sockaddr;
pub const socklen_t = posix.socklen_t;
pub const pollfd = posix.pollfd;
pub const AF = posix.AF;
pub const SOCK = posix.SOCK;
pub const IPPROTO = posix.IPPROTO;
pub const SOL = posix.SOL;
pub const SO = posix.SO;
pub const POLL = posix.POLL;
pub const E = posix.E;
pub const timeval = posix.timeval;
pub const timespec = posix.timespec;
pub const mode_t = posix.mode_t;
pub const O = posix.O;
pub const F = posix.F;

pub fn socket(domain: u32, socket_type: u32, protocol: u32) glib.std.posix.SocketError!socket_t {
    return posix.socket(domain, socket_type, protocol);
}

pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) glib.std.posix.BindError!void {
    return posix.bind(sock, addr, len);
}

pub fn listen(sock: socket_t, backlog: u31) glib.std.posix.ListenError!void {
    return posix.listen(sock, backlog);
}

pub fn accept(sock: socket_t, addr: ?*sockaddr, addrlen: ?*socklen_t, flags: u32) glib.std.posix.AcceptError!socket_t {
    return posix.accept(sock, addr, addrlen, flags);
}

pub fn connect(sock: socket_t, addr: *const sockaddr, len: socklen_t) glib.std.posix.ConnectError!void {
    return posix.connect(sock, addr, len);
}

pub fn send(sock: socket_t, buf: []const u8, flags: u32) glib.std.posix.SendError!usize {
    return posix.send(sock, buf, flags);
}

pub fn recv(sock: socket_t, buf: []u8, flags: u32) glib.std.posix.RecvFromError!usize {
    return posix.recv(sock, buf, flags);
}

pub fn sendto(sock: socket_t, buf: []const u8, flags: u32, dest_addr: ?*const sockaddr, addrlen: socklen_t) glib.std.posix.SendToError!usize {
    return posix.sendto(sock, buf, flags, dest_addr, addrlen);
}

pub fn recvfrom(sock: socket_t, buf: []u8, flags: u32, src_addr: ?*sockaddr, addrlen: ?*socklen_t) glib.std.posix.RecvFromError!usize {
    return posix.recvfrom(sock, buf, flags, src_addr, addrlen);
}

pub fn setsockopt(sock: socket_t, level: i32, optname: u32, opt: []const u8) glib.std.posix.SetSockOptError!void {
    return posix.setsockopt(sock, level, optname, opt);
}

pub fn getsockopt(sock: socket_t, level: i32, optname: u32, opt: []u8) glib.std.posix.GetSockOptError!void {
    return posix.getsockopt(sock, level, optname, opt);
}

pub fn poll(fds: []pollfd, timeout: i32) glib.std.posix.PollError!usize {
    return posix.poll(fds, timeout);
}

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) glib.std.posix.FcntlError!usize {
    return posix.fcntl(fd, cmd, arg);
}

pub fn shutdown(sock: socket_t, how: glib.std.posix.ShutdownHow) glib.std.posix.ShutdownError!void {
    return posix.shutdown(sock, how);
}

pub fn getsockname(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) glib.std.posix.GetSockNameError!void {
    return posix.getsockname(sock, addr, addrlen);
}

pub fn close(fd: fd_t) void {
    posix.close(fd);
}

pub fn open(path: []const u8, flags: O, mode: mode_t) glib.std.posix.OpenError!fd_t {
    return posix.open(path, flags, mode);
}

pub fn read(fd: fd_t, buf: []u8) glib.std.posix.ReadError!usize {
    return posix.read(fd, buf);
}

pub fn write(fd: fd_t, buf: []const u8) glib.std.posix.WriteError!usize {
    return posix.write(fd, buf);
}

pub fn lseek_SET(fd: fd_t, offset: u64) glib.std.posix.SeekError!void {
    return posix.lseek_SET(fd, offset);
}

pub fn lseek_CUR(fd: fd_t, offset: i64) glib.std.posix.SeekError!void {
    return posix.lseek_CUR(fd, offset);
}

pub fn lseek_CUR_get(fd: fd_t) glib.std.posix.SeekError!u64 {
    return posix.lseek_CUR_get(fd);
}

pub fn lseek_END(fd: fd_t, offset: i64) glib.std.posix.SeekError!void {
    return posix.lseek_END(fd, offset);
}

pub fn mkdir(path: []const u8, mode: mode_t) glib.std.posix.MakeDirError!void {
    return posix.mkdir(path, mode);
}

pub fn unlink(path: []const u8) glib.std.posix.UnlinkError!void {
    return posix.unlink(path);
}
