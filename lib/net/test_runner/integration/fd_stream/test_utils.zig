//! Shared helpers for fd `Stream` integration cases (per-case files hold the tests).

const context_mod = @import("context");
const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
const sockaddr_mod = @import("../../../fd/SockAddr.zig");
const tcp_test_utils = @import("../tcp/test_utils.zig");

// Re-export for case bodies (same semantics as TCP integration).
pub const fillPattern = tcp_test_utils.fillPattern;
pub const skipIfConnectDidNotPend = tcp_test_utils.skipIfConnectDidNotPend;
pub const ReadyCounter = tcp_test_utils.ReadyCounter;

pub fn Harness(comptime lib: type) type {
    const Stream = fd_mod.Stream(lib);
    const Addr = netip.AddrPort;
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const Thread = lib.Thread;
    const posix = lib.posix;

    return struct {
        pub const ErrorSlot = struct {
            mutex: Thread.Mutex = .{},
            err: ?anyerror = null,

            pub fn store(self: *@This(), e: anyerror) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.err == null) self.err = e;
            }

            pub fn load(self: *@This()) ?anyerror {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.err;
            }
        };

        pub fn listenLoopback() !struct {
            fd: posix.socket_t,
            port: u16,

            pub fn deinit(self: *@This()) void {
                posix.close(self.fd);
            }

            pub fn addr(self: @This()) Addr {
                return Addr.from4(.{ 127, 0, 0, 1 }, self.port);
            }
        } {
            const addr = Addr.from4(.{ 127, 0, 0, 1 }, 0);
            const encoded = try SockAddr.encode(addr);
            const listener = try posix.socket(encoded.family, posix.SOCK.STREAM, 0);
            errdefer posix.close(listener);

            const enable: [4]u8 = @bitCast(@as(i32, 1));
            posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable) catch {};

            try posix.bind(listener, @ptrCast(&encoded.storage), encoded.len);
            try posix.listen(listener, 4);

            var bound: posix.sockaddr.in = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            try posix.getsockname(listener, @ptrCast(&bound), &bound_len);

            return .{
                .fd = listener,
                .port = lib.mem.bigToNative(u16, bound.port),
            };
        }

        pub fn accept(listener_fd: posix.socket_t) !posix.socket_t {
            return posix.accept(listener_fd, null, null, 0);
        }

        pub fn acceptStream(listener_fd: posix.socket_t) !Stream {
            const fd = try accept(listener_fd);
            return Stream.adopt(fd);
        }

        pub fn setSocketBuffer(fd: posix.socket_t, optname: u32, size: i32) void {
            const raw: [4]u8 = @bitCast(size);
            posix.setsockopt(fd, posix.SOL.SOCKET, optname, &raw) catch {};
        }

        pub fn writeAll(stream: *Stream, data: []const u8) !void {
            var offset: usize = 0;
            while (offset < data.len) {
                offset += try stream.write(data[offset..]);
            }
        }

        pub fn writeAllContext(stream: *Stream, ctx: context_mod.Context, data: []const u8) !void {
            var offset: usize = 0;
            while (offset < data.len) {
                offset += try stream.writeContext(ctx, data[offset..]);
            }
        }

        pub fn readExact(stream: *Stream, buf: []u8) !void {
            var offset: usize = 0;
            while (offset < buf.len) {
                const n = try stream.read(buf[offset..]);
                if (n == 0) return error.EndOfStream;
                offset += n;
            }
        }

        pub fn unusedLoopbackAddr() !Addr {
            var listener = try listenLoopback();
            defer listener.deinit();
            return listener.addr();
        }
    };
}
