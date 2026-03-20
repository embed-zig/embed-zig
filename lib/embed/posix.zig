//! POSIX contract — cross-platform POSIX-compatible subset.
//!
//! Error sets and function signatures are defined here.
//! Impl provides platform-dependent types and function implementations.
//!
//! Impl must provide:
//!
//! Types:
//!   fd_t, socket_t, sockaddr, socklen_t, pollfd, timeval,
//!   AF, SOCK, IPPROTO, SOL, SO, POLL,
//!   mode_t, O
//!
//! Functions: (signatures verified at comptime via @as)
//!   socket, bind, listen, accept, connect,
//!   send, recv, sendto, recvfrom,
//!   setsockopt, shutdown, getsockname, poll, close,
//!   open, read, write,
//!   lseek_SET, lseek_CUR, lseek_CUR_get, lseek_END,
//!   mkdir, unlink

const std = @import("std");

pub const UnexpectedError = std.posix.UnexpectedError;
pub const SocketError = std.posix.SocketError;
pub const BindError = std.posix.BindError;
pub const ListenError = std.posix.ListenError;
pub const AcceptError = std.posix.AcceptError;
pub const ConnectError = std.posix.ConnectError;
pub const SendError = std.posix.SendError;
pub const SendToError = std.posix.SendToError;
pub const RecvFromError = std.posix.RecvFromError;
pub const SetSockOptError = std.posix.SetSockOptError;
pub const ShutdownError = std.posix.ShutdownError;
pub const PollError = std.posix.PollError;
pub const OpenError = std.posix.OpenError;
pub const ReadError = std.posix.ReadError;
pub const WriteError = std.posix.WriteError;
pub const SeekError = std.posix.SeekError;
pub const MakeDirError = std.posix.MakeDirError;
pub const UnlinkError = std.posix.UnlinkError;
pub const GetSockNameError = std.posix.GetSockNameError;
pub const ShutdownHow = std.posix.ShutdownHow;

const root = @This();

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (u32, u32, u32) SocketError!Impl.socket_t, &Impl.socket);
        _ = @as(*const fn (Impl.socket_t, *const Impl.sockaddr, Impl.socklen_t) BindError!void, &Impl.bind);
        _ = @as(*const fn (Impl.socket_t, u31) ListenError!void, &Impl.listen);
        _ = @as(*const fn (Impl.socket_t, ?*Impl.sockaddr, ?*Impl.socklen_t, u32) AcceptError!Impl.socket_t, &Impl.accept);
        _ = @as(*const fn (Impl.socket_t, *const Impl.sockaddr, Impl.socklen_t) ConnectError!void, &Impl.connect);
        _ = @as(*const fn (Impl.socket_t, []const u8, u32) SendError!usize, &Impl.send);
        _ = @as(*const fn (Impl.socket_t, []u8, u32) RecvFromError!usize, &Impl.recv);
        _ = @as(*const fn (Impl.socket_t, []const u8, u32, ?*const Impl.sockaddr, Impl.socklen_t) SendToError!usize, &Impl.sendto);
        _ = @as(*const fn (Impl.socket_t, []u8, u32, ?*Impl.sockaddr, ?*Impl.socklen_t) RecvFromError!usize, &Impl.recvfrom);
        _ = @as(*const fn (Impl.socket_t, i32, u32, []const u8) SetSockOptError!void, &Impl.setsockopt);
        _ = @as(*const fn (Impl.socket_t, ShutdownHow) ShutdownError!void, &Impl.shutdown);
        _ = @as(*const fn (Impl.socket_t, *Impl.sockaddr, *Impl.socklen_t) GetSockNameError!void, &Impl.getsockname);
        _ = @as(*const fn ([]Impl.pollfd, i32) PollError!usize, &Impl.poll);
        _ = @as(*const fn (Impl.fd_t) void, &Impl.close);

        _ = @as(*const fn ([]const u8, Impl.O, Impl.mode_t) OpenError!Impl.fd_t, &Impl.open);
        _ = @as(*const fn (Impl.fd_t, []u8) ReadError!usize, &Impl.read);
        _ = @as(*const fn (Impl.fd_t, []const u8) WriteError!usize, &Impl.write);
        _ = @as(*const fn (Impl.fd_t, u64) SeekError!void, &Impl.lseek_SET);
        _ = @as(*const fn (Impl.fd_t, i64) SeekError!void, &Impl.lseek_CUR);
        _ = @as(*const fn (Impl.fd_t) SeekError!u64, &Impl.lseek_CUR_get);
        _ = @as(*const fn (Impl.fd_t, i64) SeekError!void, &Impl.lseek_END);
        _ = @as(*const fn ([]const u8, Impl.mode_t) MakeDirError!void, &Impl.mkdir);
        _ = @as(*const fn ([]const u8) UnlinkError!void, &Impl.unlink);
    }

    return struct {
        pub const fd_t = Impl.fd_t;
        pub const socket_t = Impl.socket_t;
        pub const sockaddr = Impl.sockaddr;
        pub const socklen_t = Impl.socklen_t;
        pub const pollfd = Impl.pollfd;
        pub const AF = Impl.AF;
        pub const SOCK = Impl.SOCK;
        pub const IPPROTO = Impl.IPPROTO;
        pub const SOL = Impl.SOL;
        pub const SO = Impl.SO;
        pub const POLL = Impl.POLL;
        pub const ShutdownHow = root.ShutdownHow;
        pub const timeval = Impl.timeval;
        pub const mode_t = Impl.mode_t;
        pub const O = Impl.O;

        pub const UnexpectedError = root.UnexpectedError;
        pub const SocketError = root.SocketError;
        pub const BindError = root.BindError;
        pub const ListenError = root.ListenError;
        pub const AcceptError = root.AcceptError;
        pub const ConnectError = root.ConnectError;
        pub const SendError = root.SendError;
        pub const SendToError = root.SendToError;
        pub const RecvFromError = root.RecvFromError;
        pub const SetSockOptError = root.SetSockOptError;
        pub const ShutdownError = root.ShutdownError;
        pub const GetSockNameError = root.GetSockNameError;
        pub const PollError = root.PollError;
        pub const OpenError = root.OpenError;
        pub const ReadError = root.ReadError;
        pub const WriteError = root.WriteError;
        pub const SeekError = root.SeekError;
        pub const MakeDirError = root.MakeDirError;
        pub const UnlinkError = root.UnlinkError;

        pub fn socket(domain: u32, socket_type: u32, protocol: u32) root.SocketError!socket_t {
            return Impl.socket(domain, socket_type, protocol);
        }

        pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) root.BindError!void {
            return Impl.bind(sock, addr, len);
        }

        pub fn listen(sock: socket_t, backlog: u31) root.ListenError!void {
            return Impl.listen(sock, backlog);
        }

        pub fn accept(sock: socket_t, addr: ?*sockaddr, addrlen: ?*socklen_t, flags: u32) root.AcceptError!socket_t {
            return Impl.accept(sock, addr, addrlen, flags);
        }

        pub fn connect(sock: socket_t, addr: *const sockaddr, len: socklen_t) root.ConnectError!void {
            return Impl.connect(sock, addr, len);
        }

        pub fn send(sock: socket_t, buf: []const u8, flags: u32) root.SendError!usize {
            return Impl.send(sock, buf, flags);
        }

        pub fn recv(sock: socket_t, buf: []u8, flags: u32) root.RecvFromError!usize {
            return Impl.recv(sock, buf, flags);
        }

        pub fn sendto(sock: socket_t, buf: []const u8, flags: u32, dest_addr: ?*const sockaddr, addrlen: socklen_t) root.SendToError!usize {
            return Impl.sendto(sock, buf, flags, dest_addr, addrlen);
        }

        pub fn recvfrom(sock: socket_t, buf: []u8, flags: u32, src_addr: ?*sockaddr, addrlen: ?*socklen_t) root.RecvFromError!usize {
            return Impl.recvfrom(sock, buf, flags, src_addr, addrlen);
        }

        pub fn setsockopt(sock: socket_t, level: i32, optname: u32, opt: []const u8) root.SetSockOptError!void {
            return Impl.setsockopt(sock, level, optname, opt);
        }

        pub fn shutdown(sock: socket_t, how: root.ShutdownHow) root.ShutdownError!void {
            return Impl.shutdown(sock, how);
        }

        pub fn getsockname(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) root.GetSockNameError!void {
            return Impl.getsockname(sock, addr, addrlen);
        }

        pub fn poll(fds: []pollfd, timeout: i32) root.PollError!usize {
            return Impl.poll(fds, timeout);
        }

        pub fn close(fd: fd_t) void {
            Impl.close(fd);
        }

        pub fn open(path: []const u8, flags: O, mode: mode_t) root.OpenError!fd_t {
            return Impl.open(path, flags, mode);
        }

        pub fn read(fd: fd_t, buf: []u8) root.ReadError!usize {
            return Impl.read(fd, buf);
        }

        pub fn write(fd: fd_t, buf: []const u8) root.WriteError!usize {
            return Impl.write(fd, buf);
        }

        pub fn lseek_SET(fd: fd_t, offset: u64) root.SeekError!void {
            return Impl.lseek_SET(fd, offset);
        }

        pub fn lseek_CUR(fd: fd_t, offset: i64) root.SeekError!void {
            return Impl.lseek_CUR(fd, offset);
        }

        pub fn lseek_CUR_get(fd: fd_t) root.SeekError!u64 {
            return Impl.lseek_CUR_get(fd);
        }

        pub fn lseek_END(fd: fd_t, offset: i64) root.SeekError!void {
            return Impl.lseek_END(fd, offset);
        }

        pub fn mkdir(path: []const u8, mode: mode_t) root.MakeDirError!void {
            return Impl.mkdir(path, mode);
        }

        pub fn unlink(path: []const u8) root.UnlinkError!void {
            return Impl.unlink(path);
        }
    };
}
