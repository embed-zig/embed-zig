//! fd stream test runner — validates the internal non-blocking stream layer.

const context_mod = @import("context");
const embed = @import("embed");
const testing_api = @import("testing");
const fd_mod = @import("../../fd.zig");
const netip = @import("../../netip.zig");
const sockaddr_mod = @import("../../fd/SockAddr.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator) catch |err| {
                t.logErrorf("fd_stream runner failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type, t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    _ = t;
    const Context = context_mod.make(lib);
    const Stream = fd_mod.Stream(lib);
    const Addr = netip.AddrPort;
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const Thread = lib.Thread;
    const posix = lib.posix;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualSlices = lib.testing.expectEqualSlices;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;

    const Runner = struct {
        const ErrorSlot = struct {
            mutex: Thread.Mutex = .{},
            err: ?anyerror = null,

            fn store(self: *@This(), err: anyerror) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.err == null) self.err = err;
            }

            fn load(self: *@This()) ?anyerror {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.err;
            }
        };

        fn listenLoopback() !struct {
            fd: posix.socket_t,
            port: u16,

            fn deinit(self: *@This()) void {
                posix.close(self.fd);
            }

            fn addr(self: @This()) Addr {
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

        fn accept(listener_fd: posix.socket_t) !posix.socket_t {
            return posix.accept(listener_fd, null, null, 0);
        }

        fn acceptStream(listener_fd: posix.socket_t) !Stream {
            const fd = try accept(listener_fd);
            return Stream.adopt(fd);
        }

        fn fillPattern(buf: []u8, seed: u8) void {
            for (buf, 0..) |*byte, i| {
                byte.* = @truncate((i * 131 + seed) % 251);
            }
        }

        fn setSocketBuffer(fd: posix.socket_t, optname: u32, size: i32) void {
            const raw: [4]u8 = @bitCast(size);
            posix.setsockopt(fd, posix.SOL.SOCKET, optname, &raw) catch {};
        }

        fn writeAll(stream: *Stream, data: []const u8) !void {
            var offset: usize = 0;
            while (offset < data.len) {
                offset += try stream.write(data[offset..]);
            }
        }

        fn writeAllContext(stream: *Stream, ctx: context_mod.Context, data: []const u8) !void {
            var offset: usize = 0;
            while (offset < data.len) {
                offset += try stream.writeContext(ctx, data[offset..]);
            }
        }

        fn readExact(stream: *Stream, buf: []u8) !void {
            var offset: usize = 0;
            while (offset < buf.len) {
                const n = try stream.read(buf[offset..]);
                if (n == 0) return error.EndOfStream;
                offset += n;
            }
        }

        fn skipIfConnectDidNotPend(err: anyerror) anyerror!void {
            switch (err) {
                error.AccessDenied,
                error.PermissionDenied,
                error.AddressInUse,
                error.AddressNotAvailable,
                error.AddressFamilyNotSupported,
                error.ConnectionRefused,
                error.NetworkUnreachable,
                error.ConnectionTimedOut,
                error.ConnectionResetByPeer,
                error.FileNotFound,
                error.SystemResources,
                error.ConnectFailed,
                => return error.SkipZigTest,
                else => return err,
            }
        }

        fn unusedLoopbackAddr() !Addr {
            var listener = try listenLoopback();
            defer listener.deinit();
            return listener.addr();
        }

        fn streamConnectLoopback() !void {
            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();

            try stream.connect(listener.addr());
            const peer = try accept(listener.fd);
            defer posix.close(peer);

            _ = try posix.send(peer, "ok", 0);

            var buf: [2]u8 = undefined;
            const n = try stream.read(&buf);
            try testing.expectEqual(@as(usize, 2), n);
            try testing.expectEqualStrings("ok", buf[0..n]);
        }

        fn streamConnectContextLoopback() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();

            try stream.connectContext(ctx_api.background(), listener.addr());
            const peer = try accept(listener.fd);
            defer posix.close(peer);

            _ = try stream.write("hi");

            var buf: [2]u8 = undefined;
            const n = try posix.recv(peer, &buf, 0);
            try testing.expectEqual(@as(usize, 2), n);
            try testing.expectEqualStrings("hi", buf[0..n]);
        }

        fn streamConnectContextCanceledBeforeStart() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ctx = try ctx_api.withCancel(ctx_api.background());
            defer ctx.deinit();
            ctx.cancel();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();

            try testing.expectError(
                error.Canceled,
                stream.connectContext(ctx, Addr.from4(.{ 127, 0, 0, 1 }, 1)),
            );
        }

        fn streamConnectContextDeadlineExceededBeforeStart() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() - 1 * lib.time.ns_per_ms);
            defer ctx.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();

            try testing.expectError(
                error.DeadlineExceeded,
                stream.connectContext(ctx, Addr.from4(.{ 127, 0, 0, 1 }, 1)),
            );
        }

        fn streamConnectContextCanceledDuringConnect() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ctx = try ctx_api.withCancel(ctx_api.background());
            defer ctx.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();

            const cancel_thread = try Thread.spawn(.{}, struct {
                fn run(cancel_ctx: context_mod.Context, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(40 * thread_lib.time.ns_per_ms);
                    cancel_ctx.cancel();
                }
            }.run, .{ ctx, lib });
            defer cancel_thread.join();

            stream.connectContext(ctx, Addr.from4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                error.Canceled => return,
                else => return skipIfConnectDidNotPend(err),
            };

            return error.ExpectedCanceledConnect;
        }

        fn streamConnectContextDeadlineExceededDuringConnect() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();

            var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 40 * lib.time.ns_per_ms);
            defer ctx.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();

            stream.connectContext(ctx, Addr.from4(.{ 203, 0, 113, 1 }, 9)) catch |err| switch (err) {
                error.DeadlineExceeded => return,
                else => return skipIfConnectDidNotPend(err),
            };

            return error.ExpectedDeadlineExceeded;
        }

        fn streamConnectRefusedKeepsSpecificError() !void {
            const addr = try unusedLoopbackAddr();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();

            try testing.expectError(error.ConnectionRefused, stream.connect(addr));
        }

        fn streamReadWaitsUntilReadable() !void {
            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            const writer = try Thread.spawn(.{}, struct {
                fn run(fd: posix.socket_t, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                    _ = thread_lib.posix.send(fd, "ping", 0) catch {};
                }
            }.run, .{ peer, lib });
            defer writer.join();

            var buf: [8]u8 = undefined;
            const n = try stream.read(&buf);
            try testing.expectEqual(@as(usize, 4), n);
            try testing.expectEqualStrings("ping", buf[0..n]);
        }

        fn streamWriteWaitsUntilWritable() !void {
            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            setSocketBuffer(stream.fd, posix.SO.SNDBUF, 4096);

            const payload = try testing.allocator.alloc(u8, 512 * 1024);
            defer testing.allocator.free(payload);
            @memset(payload, 'w');

            const reader = try Thread.spawn(.{}, struct {
                fn run(fd: posix.socket_t, expected: usize, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(40 * thread_lib.time.ns_per_ms);

                    var received: usize = 0;
                    var buf: [4096]u8 = undefined;
                    while (received < expected) {
                        const n = thread_lib.posix.recv(fd, &buf, 0) catch break;
                        if (n == 0) break;
                        received += n;
                    }
                }
            }.run, .{ peer, payload.len, lib });
            defer reader.join();

            stream.setWriteDeadline(lib.time.milliTimestamp() + 1000);
            try writeAll(&stream, payload);
        }

        fn streamFullDuplexConcurrentStreaming() !void {
            var listener = try listenLoopback();
            defer listener.deinit();

            var client = try Stream.initSocket(posix.AF.INET);
            defer client.deinit();
            try client.connect(listener.addr());

            var server = try acceptStream(listener.fd);
            defer server.deinit();

            setSocketBuffer(client.fd, posix.SO.SNDBUF, 4096);
            setSocketBuffer(server.fd, posix.SO.SNDBUF, 4096);
            client.setDeadline(lib.time.milliTimestamp() + 3000);
            server.setDeadline(lib.time.milliTimestamp() + 3000);

            const client_send = try testing.allocator.alloc(u8, 128 * 1024);
            defer testing.allocator.free(client_send);
            const server_send = try testing.allocator.alloc(u8, 128 * 1024);
            defer testing.allocator.free(server_send);
            const client_recv = try testing.allocator.alloc(u8, server_send.len);
            defer testing.allocator.free(client_recv);
            const server_recv = try testing.allocator.alloc(u8, client_send.len);
            defer testing.allocator.free(server_recv);

            fillPattern(client_send, 11);
            fillPattern(server_send, 29);

            var slot = ErrorSlot{};

            const client_writer = try Thread.spawn(.{}, struct {
                fn run(err_slot: *ErrorSlot, stream: *Stream, buf: []const u8) void {
                    writeAll(stream, buf) catch |err| err_slot.store(err);
                }
            }.run, .{ &slot, &client, client_send });

            const client_reader = try Thread.spawn(.{}, struct {
                fn run(err_slot: *ErrorSlot, stream: *Stream, buf: []u8) void {
                    readExact(stream, buf) catch |err| err_slot.store(err);
                }
            }.run, .{ &slot, &client, client_recv });

            const server_writer = try Thread.spawn(.{}, struct {
                fn run(err_slot: *ErrorSlot, stream: *Stream, buf: []const u8) void {
                    writeAll(stream, buf) catch |err| err_slot.store(err);
                }
            }.run, .{ &slot, &server, server_send });

            const server_reader = try Thread.spawn(.{}, struct {
                fn run(err_slot: *ErrorSlot, stream: *Stream, buf: []u8) void {
                    readExact(stream, buf) catch |err| err_slot.store(err);
                }
            }.run, .{ &slot, &server, server_recv });

            client_writer.join();
            client_reader.join();
            server_writer.join();
            server_reader.join();

            if (slot.load()) |err| return err;

            try testing.expectEqualSlices(u8, server_send, client_recv);
            try testing.expectEqualSlices(u8, client_send, server_recv);
        }

        fn streamReadDeadlineTimesOut() !void {
            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            stream.setReadDeadline(lib.time.milliTimestamp() + 20);

            var buf: [16]u8 = undefined;
            try testing.expectError(error.TimedOut, stream.read(&buf));
        }

        fn streamReadContextCanceledWhileBlocked() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();
            var ctx = try ctx_api.withCancel(ctx_api.background());
            defer ctx.deinit();

            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            const cancel_thread = try Thread.spawn(.{}, struct {
                fn run(cancel_ctx: context_mod.Context, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                    cancel_ctx.cancel();
                }
            }.run, .{ ctx, lib });
            defer cancel_thread.join();

            var buf: [16]u8 = undefined;
            try testing.expectError(error.Canceled, stream.readContext(ctx, &buf));
        }

        fn streamReadContextDeadlineExceededWhileBlocked() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();
            var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 30 * lib.time.ns_per_ms);
            defer ctx.deinit();

            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            var buf: [16]u8 = undefined;
            try testing.expectError(error.DeadlineExceeded, stream.readContext(ctx, &buf));
        }

        fn streamWriteDeadlineTimesOut() !void {
            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            setSocketBuffer(stream.fd, posix.SO.SNDBUF, 4096);

            const payload = try testing.allocator.alloc(u8, 512 * 1024);
            defer testing.allocator.free(payload);
            @memset(payload, 't');

            stream.setWriteDeadline(lib.time.milliTimestamp() + 30);
            try testing.expectError(error.TimedOut, writeAll(&stream, payload));
        }

        fn streamWriteContextCanceledWhileBlocked() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();
            var ctx = try ctx_api.withCancel(ctx_api.background());
            defer ctx.deinit();

            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            setSocketBuffer(stream.fd, posix.SO.SNDBUF, 4096);

            const payload = try testing.allocator.alloc(u8, 512 * 1024);
            defer testing.allocator.free(payload);
            @memset(payload, 'c');

            const cancel_thread = try Thread.spawn(.{}, struct {
                fn run(cancel_ctx: context_mod.Context, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                    cancel_ctx.cancel();
                }
            }.run, .{ ctx, lib });
            defer cancel_thread.join();

            try testing.expectError(error.Canceled, writeAllContext(&stream, ctx, payload));
        }

        fn streamWriteContextDeadlineExceededWhileBlocked() !void {
            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();
            var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 30 * lib.time.ns_per_ms);
            defer ctx.deinit();

            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            setSocketBuffer(stream.fd, posix.SO.SNDBUF, 4096);

            const payload = try testing.allocator.alloc(u8, 512 * 1024);
            defer testing.allocator.free(payload);
            @memset(payload, 'd');

            try testing.expectError(error.DeadlineExceeded, writeAllContext(&stream, ctx, payload));
        }

        fn streamReadDeadlineClearAllowsLaterRead() !void {
            var listener = try listenLoopback();
            defer listener.deinit();

            var stream = try Stream.initSocket(posix.AF.INET);
            defer stream.deinit();
            try stream.connect(listener.addr());

            const peer = try accept(listener.fd);
            defer posix.close(peer);

            stream.setReadDeadline(lib.time.milliTimestamp() + 20);
            var buf: [4]u8 = undefined;
            try testing.expectError(error.TimedOut, stream.read(&buf));

            stream.setReadDeadline(null);
            const writer = try Thread.spawn(.{}, struct {
                fn run(fd: posix.socket_t, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                    _ = thread_lib.posix.send(fd, "okay", 0) catch {};
                }
            }.run, .{ peer, lib });
            defer writer.join();

            try readExact(&stream, &buf);
            try testing.expectEqualStrings("okay", &buf);
        }

        fn streamOpsAfterCloseReturnClosed() !void {
            var stream = try Stream.initSocket(posix.AF.INET);
            stream.close();

            var read_buf: [1]u8 = undefined;
            try testing.expectError(error.Closed, stream.read(&read_buf));
            try testing.expectError(error.Closed, stream.write("x"));
            try testing.expectError(error.Closed, stream.shutdown(.both));
        }

        fn streamCloseIsIdempotent() !void {
            var stream = try Stream.initSocket(posix.AF.INET);
            stream.close();
            stream.close();

            var buf: [1]u8 = undefined;
            try testing.expectError(error.Closed, stream.read(&buf));
        }
    };

    try Runner.streamConnectLoopback();
    try Runner.streamConnectContextLoopback();
    try Runner.streamConnectContextCanceledBeforeStart();
    try Runner.streamConnectContextDeadlineExceededBeforeStart();
    Runner.streamConnectContextCanceledDuringConnect() catch |err| switch (err) {
        error.SkipZigTest => {},
        else => return err,
    };
    Runner.streamConnectContextDeadlineExceededDuringConnect() catch |err| switch (err) {
        error.SkipZigTest => {},
        else => return err,
    };
    try Runner.streamConnectRefusedKeepsSpecificError();
    try Runner.streamReadWaitsUntilReadable();
    try Runner.streamWriteWaitsUntilWritable();
    try Runner.streamFullDuplexConcurrentStreaming();
    try Runner.streamReadDeadlineTimesOut();
    try Runner.streamReadContextCanceledWhileBlocked();
    try Runner.streamReadContextDeadlineExceededWhileBlocked();
    try Runner.streamWriteDeadlineTimesOut();
    try Runner.streamWriteContextCanceledWhileBlocked();
    try Runner.streamWriteContextDeadlineExceededWhileBlocked();
    try Runner.streamReadDeadlineClearAllowsLaterRead();
    try Runner.streamOpsAfterCloseReturnClosed();
    try Runner.streamCloseIsIdempotent();
}
