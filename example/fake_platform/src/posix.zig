//! Example posix impl — direct re-export of std.posix.

const std = @import("std");
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
pub const mode_t = posix.mode_t;
pub const O = posix.O;

pub const socket = posix.socket;
pub const bind = posix.bind;
pub const listen = posix.listen;
pub const accept = posix.accept;
pub const connect = posix.connect;
pub const send = posix.send;
pub const recv = posix.recv;
pub const sendto = posix.sendto;
pub const recvfrom = posix.recvfrom;
pub const setsockopt = posix.setsockopt;
pub const poll = posix.poll;

const embed_posix = @import("embed").posix;

pub fn shutdown(sock: socket_t, how: embed_posix.ShutdownHow) embed_posix.ShutdownError!void {
    return posix.shutdown(sock, @enumFromInt(@intFromEnum(how)));
}

pub fn getsockname(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) embed_posix.GetSockNameError!void {
    return posix.getsockname(sock, addr, addrlen);
}
pub const close = posix.close;

pub const open = posix.open;
pub const read = posix.read;
pub const write = posix.write;
pub const lseek_SET = posix.lseek_SET;
pub const lseek_CUR = posix.lseek_CUR;
pub const lseek_CUR_get = posix.lseek_CUR_get;
pub const lseek_END = posix.lseek_END;
pub const mkdir = posix.mkdir;
pub const unlink = posix.unlink;
