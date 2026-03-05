const esp = @import("esp");
const runtime = @import("runtime");

const lwip = esp.lwip.socket;
const Ipv4Address = runtime.socket.Ipv4Address;
const SockError = runtime.socket.Error;
const RecvFromResult = runtime.socket.RecvFromResult;

pub const Socket = struct {
    fd: i32 = -1,
    is_udp: bool = false,

    pub fn tcp() SockError!@This() {
        const fd = lwip.socket(lwip.SOCK_STREAM, lwip.IPPROTO_TCP) catch return error.CreateFailed;
        return .{ .fd = fd, .is_udp = false };
    }

    pub fn udp() SockError!@This() {
        const fd = lwip.socket(lwip.SOCK_DGRAM, lwip.IPPROTO_UDP) catch return error.CreateFailed;
        return .{ .fd = fd, .is_udp = true };
    }

    pub fn close(self: *@This()) void {
        if (self.fd >= 0) {
            lwip.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn connect(self: *@This(), addr: Ipv4Address, port: u16) SockError!void {
        const fd = try self.requireFd();
        lwip.connect(fd, addr, port) catch return error.ConnectFailed;
    }

    pub fn send(self: *@This(), data: []const u8) SockError!usize {
        const fd = try self.requireFd();
        return lwip.send(fd, data) catch return error.SendFailed;
    }

    pub fn recv(self: *@This(), buf: []u8) SockError!usize {
        const fd = try self.requireFd();
        const n = lwip.recv(fd, buf) catch return error.RecvFailed;
        if (n == 0 and !self.is_udp) return error.Closed;
        return n;
    }

    pub fn setRecvTimeout(self: *@This(), timeout_ms: u32) void {
        if (self.fd >= 0) lwip.setRecvTimeout(self.fd, timeout_ms) catch {};
    }

    pub fn setSendTimeout(self: *@This(), timeout_ms: u32) void {
        if (self.fd >= 0) lwip.setSendTimeout(self.fd, timeout_ms) catch {};
    }

    pub fn setTcpNoDelay(self: *@This(), enabled: bool) void {
        if (self.fd >= 0) lwip.setTcpNoDelay(self.fd, enabled) catch {};
    }

    pub fn sendTo(self: *@This(), addr: Ipv4Address, port: u16, data: []const u8) SockError!usize {
        const fd = try self.requireFd();
        return lwip.sendTo(fd, addr, port, data) catch return error.SendFailed;
    }

    pub fn recvFrom(self: *@This(), buf: []u8) SockError!RecvFromResult {
        const fd = try self.requireFd();
        const result = lwip.recvFrom(fd, buf) catch return error.RecvFailed;
        return .{
            .len = result.len,
            .src_addr = result.addr,
            .src_port = result.port,
        };
    }

    pub fn bind(self: *@This(), addr: Ipv4Address, port: u16) SockError!void {
        const fd = try self.requireFd();
        lwip.bind(fd, addr, port) catch return error.BindFailed;
    }

    pub fn getBoundPort(self: *@This()) SockError!u16 {
        const fd = try self.requireFd();
        return lwip.getBoundPort(fd) catch return error.BindFailed;
    }

    pub fn listen(self: *@This()) SockError!void {
        const fd = try self.requireFd();
        lwip.listen(fd, 128) catch return error.ListenFailed;
    }

    pub fn accept(self: *@This()) SockError!@This() {
        const fd = try self.requireFd();
        const client_fd = lwip.accept(fd) catch return error.AcceptFailed;
        return .{ .fd = client_fd, .is_udp = false };
    }

    pub fn getFd(self: *@This()) i32 {
        return self.fd;
    }

    pub fn setNonBlocking(self: *@This(), enabled: bool) SockError!void {
        const fd = try self.requireFd();
        lwip.setNonBlocking(fd, enabled) catch return error.SetOptionFailed;
    }

    fn requireFd(self: *@This()) SockError!i32 {
        if (self.fd < 0) return error.Closed;
        return self.fd;
    }
};
