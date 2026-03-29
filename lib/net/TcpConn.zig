//! TcpConn — constructs a Conn over a TCP socket fd (like Go's net.TCPConn).
//!
//! Returns a Conn directly. The internal state is heap-allocated and
//! freed on deinit().

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

        const Self = @This();

        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            self.applyReadTimeout();
            return self.stream.read(buf) catch |err| return switch (err) {
                error.Closed => error.EndOfStream,
                error.TimedOut => error.TimedOut,
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.ConnectionRefused => error.ConnectionRefused,
                else => error.Unexpected,
            };
        }

        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.closed) return error.BrokenPipe;
            self.applyWriteTimeout();
            return self.stream.write(buf) catch |err| return switch (err) {
                error.Closed => error.BrokenPipe,
                error.TimedOut => error.TimedOut,
                error.ConnectionResetByPeer => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                else => error.Unexpected,
            };
        }

        pub fn close(self: *Self) void {
            if (!self.closed) {
                self.stream.shutdown(.both) catch {};
                self.stream.close();
                self.closed = true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.close();
            const a = self.allocator;
            a.destroy(self);
        }

        pub fn setReadTimeout(self: *Self, ms: ?u32) void {
            self.read_timeout_ms = ms;
        }

        pub fn setWriteTimeout(self: *Self, ms: ?u32) void {
            self.write_timeout_ms = ms;
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
