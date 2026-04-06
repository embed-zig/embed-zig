//! TcpConn — constructs a Conn over a TCP socket fd (like Go's net.TCPConn).
//!
//! Returns a Conn directly. The internal state is heap-allocated and
//! freed on deinit().

const context_mod = @import("context");
const Conn = @import("Conn.zig");
const fd_mod = @import("fd.zig");

pub fn TcpConn(comptime lib: type) type {
    const posix = lib.posix;
    const Allocator = lib.mem.Allocator;
    const Stream = fd_mod.Stream(lib);

    return struct {
        fd: posix.socket_t,
        stream: Stream,
        allocator: Allocator,
        closed: bool = false,
        read_timeout_ms: ?u32 = null,
        write_timeout_ms: ?u32 = null,
        io_context_mu: lib.Thread.Mutex = .{},
        io_context: ?context_mod.Context = null,
        io_context_users: usize = 0,

        const Self = @This();

        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            if (buf.len == 0) return 0;
            self.applyReadTimeout();
            const n = self.readWithActiveContext(buf) catch |err| return switch (err) {
                error.Closed => error.EndOfStream,
                error.Canceled => error.TimedOut,
                error.DeadlineExceeded => error.TimedOut,
                error.TimedOut => error.TimedOut,
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.ConnectionRefused => error.ConnectionRefused,
                else => error.Unexpected,
            };
            if (n == 0) return error.EndOfStream;
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.closed) return error.BrokenPipe;
            self.applyWriteTimeout();
            return self.writeWithActiveContext(buf) catch |err| return switch (err) {
                error.Closed => error.BrokenPipe,
                error.Canceled => error.TimedOut,
                error.DeadlineExceeded => error.TimedOut,
                error.TimedOut => error.TimedOut,
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                else => error.Unexpected,
            };
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                self.closed = true;
                self.stream.shutdown(.both) catch {};
            }
        }

        pub fn deinit(self: *Self) void {
            self.close();
            if (!self.stream.closed) self.stream.close();
            const a = self.allocator;
            a.destroy(self);
        }

        pub fn setReadTimeout(self: *Self, ms: ?u32) void {
            self.read_timeout_ms = ms;
        }

        pub fn setWriteTimeout(self: *Self, ms: ?u32) void {
            self.write_timeout_ms = ms;
        }

        pub fn pushIoContext(self: *Self, ctx: context_mod.Context) void {
            self.io_context_mu.lock();
            defer self.io_context_mu.unlock();
            self.io_context = ctx;
            self.io_context_users += 1;
        }

        pub fn popIoContext(self: *Self) void {
            self.io_context_mu.lock();
            defer self.io_context_mu.unlock();
            if (self.io_context_users == 0) return;
            self.io_context_users -= 1;
            if (self.io_context_users == 0) self.io_context = null;
        }

        fn applyReadTimeout(self: *Self) void {
            self.stream.setReadDeadline(timeoutToDeadline(self.read_timeout_ms));
        }

        fn applyWriteTimeout(self: *Self) void {
            self.stream.setWriteDeadline(timeoutToDeadline(self.write_timeout_ms));
        }

        fn timeoutToDeadline(ms: ?u32) ?i64 {
            const timeout_ms = ms orelse return null;
            return lib.time.milliTimestamp() + timeout_ms;
        }

        fn activeIoContext(self: *Self) ?context_mod.Context {
            self.io_context_mu.lock();
            defer self.io_context_mu.unlock();
            if (self.io_context_users == 0) return null;
            return self.io_context;
        }

        fn readWithActiveContext(self: *Self, buf: []u8) (fd_mod.Stream(lib).ReadContextError)!usize {
            if (self.activeIoContext()) |ctx| return self.stream.readContext(ctx, buf);
            return self.stream.read(buf);
        }

        fn writeWithActiveContext(self: *Self, buf: []const u8) (fd_mod.Stream(lib).WriteContextError)!usize {
            if (self.activeIoContext()) |ctx| return self.stream.writeContext(ctx, buf);
            return self.stream.write(buf);
        }

        pub fn initFromStream(allocator: Allocator, stream: Stream) Allocator.Error!Conn {
            const self = try allocator.create(Self);
            self.* = .{
                .fd = stream.fd,
                .stream = stream,
                .allocator = allocator,
            };
            return Conn.init(self);
        }

        pub fn init(allocator: Allocator, fd: posix.socket_t) !Conn {
            const stream = try Stream.adopt(fd);
            return initFromStream(allocator, stream);
        }
    };
}
