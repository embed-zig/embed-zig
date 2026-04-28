const stdz = @import("stdz");
const testing_api = @import("testing");

pub fn make(comptime lib: type) type {
    const posix = lib.posix;

    return struct {
        recv_fd: posix.socket_t,
        send_fd: posix.socket_t,

        const Self = @This();
        const loopback_addr = [4]u8{ 127, 0, 0, 1 };
        const loopback_addr_u32 = @as(*align(1) const u32, @ptrCast(&loopback_addr)).*;
        const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

        pub const InitError =
            posix.SocketError ||
            posix.BindError ||
            posix.GetSockNameError ||
            posix.ConnectError ||
            posix.FcntlError;

        pub fn init() InitError!Self {
            const recv_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(recv_fd);

            try setNonBlocking(recv_fd);

            var recv_storage: posix.sockaddr.storage = undefined;
            zeroStorage(&recv_storage);
            const recv_addr: *posix.sockaddr.in = @ptrCast(@alignCast(&recv_storage));
            recv_addr.* = .{
                .port = 0,
                .addr = loopback_addr_u32,
            };
            try posix.bind(recv_fd, @ptrCast(&recv_storage), @sizeOf(posix.sockaddr.in));

            var bound_addr: posix.sockaddr.in = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            try posix.getsockname(recv_fd, @ptrCast(&bound_addr), &bound_len);

            const send_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
            errdefer posix.close(send_fd);

            try setNonBlocking(send_fd);

            var send_storage: posix.sockaddr.storage = undefined;
            zeroStorage(&send_storage);
            const send_addr: *posix.sockaddr.in = @ptrCast(@alignCast(&send_storage));
            send_addr.* = .{
                .port = bound_addr.port,
                .addr = loopback_addr_u32,
            };
            try posix.connect(send_fd, @ptrCast(&send_storage), @sizeOf(posix.sockaddr.in));

            return .{
                .recv_fd = recv_fd,
                .send_fd = send_fd,
            };
        }

        pub fn deinit(self: *Self) void {
            posix.close(self.send_fd);
            posix.close(self.recv_fd);
            self.* = undefined;
        }

        pub fn signal(self: *const Self) void {
            const wake_byte = [_]u8{0};
            _ = posix.send(self.send_fd, wake_byte[0..], 0) catch {};
        }

        pub fn drain(self: *const Self) void {
            var buf: [32]u8 = undefined;

            while (true) {
                _ = posix.recv(self.recv_fd, buf[0..], 0) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return,
                };
            }
        }

        fn zeroStorage(storage: *posix.sockaddr.storage) void {
            const bytes: *[@sizeOf(posix.sockaddr.storage)]u8 = @ptrCast(storage);
            @memset(bytes, 0);
        }

        fn setNonBlocking(fd: posix.socket_t) posix.FcntlError!void {
            const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
            if ((flags & nonblock_flag) != 0) return;
            _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const WakeFd = make(lib);
    const Cases = struct {
        fn initAndSignalCase(comptime test_lib: type) !void {
            const testing = test_lib.testing;

            var wake = try WakeFd.init();
            defer wake.deinit();

            wake.signal();
            var poll_fds = [_]test_lib.posix.pollfd{
                .{
                    .fd = wake.recv_fd,
                    .events = test_lib.posix.POLL.IN,
                    .revents = 0,
                },
            };
            const ready = try test_lib.posix.poll(poll_fds[0..], 50);
            try testing.expectEqual(@as(usize, 1), ready);
            try testing.expect((poll_fds[0].revents & test_lib.posix.POLL.IN) != 0);

            try expectDrained(test_lib, &wake);
        }

        fn drainIsIdempotentCase(comptime test_lib: type) !void {
            const testing = test_lib.testing;

            var wake = try WakeFd.init();
            defer wake.deinit();

            wake.drain();
            wake.signal();
            wake.signal();

            var poll_fds = [_]test_lib.posix.pollfd{
                .{
                    .fd = wake.recv_fd,
                    .events = test_lib.posix.POLL.IN,
                    .revents = 0,
                },
            };
            const ready = try test_lib.posix.poll(poll_fds[0..], 50);
            try testing.expectEqual(@as(usize, 1), ready);

            try expectDrained(test_lib, &wake);
            wake.drain();
        }

        fn expectDrained(comptime test_lib: type, wake: *const WakeFd) !void {
            const testing = test_lib.testing;
            var poll_fds = [_]test_lib.posix.pollfd{
                .{
                    .fd = wake.recv_fd,
                    .events = test_lib.posix.POLL.IN,
                    .revents = 0,
                },
            };

            var ready: usize = 0;
            for (0..8) |_| {
                wake.drain();
                poll_fds[0].revents = 0;
                ready = try test_lib.posix.poll(poll_fds[0..], 2);
                if (ready == 0) return;
            }
            try testing.expectEqual(@as(usize, 0), ready);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            Cases.initAndSignalCase(lib) catch |err| {
                t.logErrorf("sync.WakeFd init/signal failed: {}", .{err});
                return false;
            };
            Cases.drainIsIdempotentCase(lib) catch |err| {
                t.logErrorf("sync.WakeFd drain failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
