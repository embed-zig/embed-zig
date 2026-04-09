//! TcpListener — binds a TCP port and starts listening on demand.
//!
//! `init()` binds but does not call `listen()`. Callers can invoke `listen()`
//! directly, or use `net.listen(...)` / `net.tls.listen(...)` for a one-shot
//! bind+listen convenience.

const Conn = @import("Conn.zig");
const Listener = @import("Listener.zig");
const tcp_conn = @import("TcpConn.zig");
const fd_mod = @import("fd.zig");
const testing_api = @import("testing");

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

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 0, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Addr = @import("netip/AddrPort.zig");
            const TL = TcpListener(lib);

            {
                var ln = try TL.init(allocator, .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
                defer ln.deinit();
                try ln.listen();
                ln.close();

                try testing.expectError(error.Closed, ln.accept());
            }

            {
                var ln = try TL.init(allocator, .{ .address = Addr.from4(.{ 127, 0, 0, 1 }, 0) });
                defer ln.deinit();

                try testing.expectError(error.SocketNotListening, ln.accept());
            }
        }
    }.run);
}
