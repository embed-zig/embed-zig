//! TcpListener — binds a TCP port and starts listening on demand.
//!
//! `init()` binds but does not call `listen()`. Callers can invoke `listen()`
//! directly, or use `net.listen(...)` / `net.tls.listen(...)` for a one-shot
//! bind+listen convenience.

const Conn = @import("Conn.zig");
const Listener = @import("Listener.zig");
const tcp_conn = @import("TcpConn.zig");
const fd_mod = @import("fd.zig");
const sockaddr_mod = @import("fd/SockAddr.zig");

pub fn TcpListener(comptime lib: type) type {
    const AddrPort = @import("netip/AddrPort.zig");
    const Allocator = lib.mem.Allocator;
    const FdListener = fd_mod.Listener(lib);
    const SC = tcp_conn.TcpConn(lib);

    return struct {
        listener: FdListener,
        allocator: Allocator,
        backlog: u31,

        const Self = @This();

        pub const Options = struct {
            address: AddrPort = AddrPort.from4(.{ 0, 0, 0, 0 }, 0),
            backlog: u31 = 128,
            reuse_addr: bool = true,
        };

        pub fn init(allocator: Allocator, opts: Options) !Listener {
            const listener = try FdListener.init(opts.address, opts.reuse_addr);

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .listener = listener,
                .allocator = allocator,
                .backlog = opts.backlog,
            };
            return Listener.init(self);
        }

        pub fn listen(self: *Self) Listener.ListenError!void {
            try self.listener.listen(self.backlog);
        }

        pub fn accept(self: *Self) Listener.AcceptError!Conn {
            var stream = self.listener.accept() catch |err| return switch (err) {
                error.BlockedByFirewall => error.BlockedByFirewall,
                error.Closed => error.Closed,
                error.SocketNotListening => error.SocketNotListening,
                error.ConnectionAborted => error.ConnectionAborted,
                error.ConnectionResetByPeer => error.ConnectionResetByPeer,
                error.DeadLock => error.DeadLock,
                error.FileDescriptorNotASocket => error.FileDescriptorNotASocket,
                error.FileBusy => error.FileBusy,
                error.Locked => error.Locked,
                error.LockedRegionLimitExceeded => error.LockedRegionLimitExceeded,
                error.NetworkSubsystemFailed => error.NetworkSubsystemFailed,
                error.OperationNotSupported => error.OperationNotSupported,
                error.PermissionDenied => error.PermissionDenied,
                error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
                error.ProtocolFailure => error.ProtocolFailure,
                error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
                error.SystemResources => error.SystemResources,
                error.WouldBlock => error.WouldBlock,
                else => error.Unexpected,
            };
            errdefer stream.deinit();

            return SC.initFromStream(self.allocator, stream) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
            };
        }

        pub fn close(self: *Self) void {
            self.listener.close();
        }

        pub fn deinit(self: *Self) void {
            self.listener.deinit();
            self.allocator.destroy(self);
        }

        pub const PortError = FdListener.PortError;

        pub fn port(self: *Self) PortError!u16 {
            return self.listener.port();
        }
    };
}

test "net/unit_tests/TcpListener/std_compat_ipv4" {
    const s = @import("std");
    const Addr = @import("netip/AddrPort.zig");
    const SockAddr = sockaddr_mod.SockAddr(s);
    const TL = TcpListener(s);

    var ln = try TL.init(s.testing.allocator, .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.deinit();
    try ln.listen();

    const typed = try ln.as(TL);

    const bound_port = try typed.port();

    const cli_fd = try s.posix.socket(s.posix.AF.INET, s.posix.SOCK.STREAM, 0);
    const dest = try SockAddr.encode(Addr.from4(.{ 127, 0, 0, 1 }, bound_port));
    try s.posix.connect(cli_fd, @ptrCast(&dest.storage), dest.len);

    var cc = try tcp_conn.TcpConn(s).init(s.testing.allocator, cli_fd);
    defer cc.deinit();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello Listener";
    _ = try cc.write(msg);

    var buf: [64]u8 = undefined;
    var n = try ac.read(buf[0..]);
    try s.testing.expectEqualStrings(msg, buf[0..n]);

    _ = try ac.write("back");
    n = try cc.read(buf[0..]);
    try s.testing.expectEqualStrings("back", buf[0..n]);
}

test "net/unit_tests/TcpListener/std_compat_ipv6" {
    const s = @import("std");
    const Addr = @import("netip/AddrPort.zig");
    const IpAddr = @import("netip/Addr.zig");
    const SockAddr = sockaddr_mod.SockAddr(s);
    const TL = TcpListener(s);

    const loopback_v6 = Addr.init(try IpAddr.parse("::1"), 0);

    var ln = try TL.init(s.testing.allocator, .{ .address = loopback_v6 });
    defer ln.deinit();
    try ln.listen();

    const typed = try ln.as(TL);

    const bound_port = try typed.port();

    const dest = try SockAddr.encode(loopback_v6.withPort(bound_port));

    const cli_fd = try s.posix.socket(s.posix.AF.INET6, s.posix.SOCK.STREAM, 0);
    try s.posix.connect(cli_fd, @ptrCast(&dest.storage), dest.len);

    var cc = try tcp_conn.TcpConn(s).init(s.testing.allocator, cli_fd);
    defer cc.deinit();

    var ac = try ln.accept();
    defer ac.deinit();

    const msg = "hello v6 Listener";
    _ = try cc.write(msg);

    var buf: [64]u8 = undefined;
    const n = try ac.read(buf[0..]);
    try s.testing.expectEqualStrings(msg, buf[0..n]);
}

test "net/unit_tests/TcpListener/accept_after_close_returns_closed" {
    const s = @import("std");
    const Addr = @import("netip/AddrPort.zig");
    const TL = TcpListener(s);

    var ln = try TL.init(s.testing.allocator, .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.deinit();
    try ln.listen();
    ln.close();

    try s.testing.expectError(error.Closed, ln.accept());
}

test "net/unit_tests/TcpListener/accept_before_listen_returns_socket_not_listening" {
    const s = @import("std");
    const Addr = @import("netip/AddrPort.zig");
    const TL = TcpListener(s);

    var ln = try TL.init(s.testing.allocator, .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.deinit();

    try s.testing.expectError(error.SocketNotListening, ln.accept());
}

test "net/unit_tests/TcpListener/accept_reports_out_of_memory" {
    const s = @import("std");
    const Addr = @import("netip/AddrPort.zig");
    const SockAddr = sockaddr_mod.SockAddr(s);
    const TL = TcpListener(s);

    const OneShotAllocator = struct {
        backing: s.mem.Allocator,
        allocations_left: usize = 1,

        const Self = @This();
        const Alignment = s.mem.Alignment;

        fn allocator(self: *Self) s.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.allocations_left == 0) return null;
            self.allocations_left -= 1;
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }

        const vtable: s.mem.Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };

    var allocator = OneShotAllocator{ .backing = s.heap.page_allocator };
    var ln = try TL.init(allocator.allocator(), .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
    defer ln.deinit();
    try ln.listen();

    const typed = try ln.as(TL);
    const bound_port = try typed.port();
    const dest = try SockAddr.encode(Addr.from4(.{ 127, 0, 0, 1 }, bound_port));

    const cli_fd = try s.posix.socket(s.posix.AF.INET, s.posix.SOCK.STREAM, 0);
    defer s.posix.close(cli_fd);
    try s.posix.connect(cli_fd, @ptrCast(&dest.storage), dest.len);

    try s.testing.expectError(error.OutOfMemory, ln.accept());
}
