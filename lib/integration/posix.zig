const std = @import("std");
const embed = @import("embed");
const testing_mod = @import("testing");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runImpl(lib) catch |err| {
                t.logFatal(@errorName(err));
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
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type) !void {
    try typeSurfaceTest(lib);
    try fileTest(lib);
    try seekTests(lib);
    try fcntlTest(lib);
    try getsockoptTest(lib);
    try tcpTest(lib);
    try udpTest(lib);
}

fn typeSurfaceTest(comptime lib: type) !void {
    const posix = lib.posix;

    _ = posix.timeval;
    _ = posix.timespec;
    if (@sizeOf(posix.timespec) == 0) return error.TimespecTypeMissing;
}

fn fileTest(comptime lib: type) !void {
    const posix = lib.posix;

    const file_path = "/tmp/embed_test_runner_test.txt";

    const fd = try posix.open(file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const msg = "hello from test_runner!\n";
    _ = try posix.write(fd, msg);

    _ = try posix.lseek_CUR_get(fd);

    try posix.lseek_SET(fd, 0);
    posix.close(fd);

    const rfd = try posix.open(file_path, .{ .ACCMODE = .RDONLY }, 0);
    var buf: [128]u8 = undefined;
    _ = try posix.read(rfd, &buf);
    posix.close(rfd);

    try posix.unlink(file_path);
}

fn seekTests(comptime lib: type) !void {
    const posix = lib.posix;

    const path = "/tmp/embed_seek_test.txt";

    const fd = try posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    _ = try posix.write(fd, "ABCDEFGHIJ");
    posix.close(fd);

    const fd2 = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(fd2);

    try posix.lseek_SET(fd2, 3);
    var pos = try posix.lseek_CUR_get(fd2);
    if (pos != 3) return error.SeekSetFailed;

    try posix.lseek_CUR(fd2, 2);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 5) return error.SeekCurFailed;

    try posix.lseek_CUR(fd2, -1);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 4) return error.SeekCurNegFailed;

    try posix.lseek_END(fd2, 0);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 10) return error.SeekEndFailed;

    try posix.lseek_END(fd2, -3);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 7) return error.SeekEndNegFailed;

    var buf: [1]u8 = undefined;
    _ = try posix.read(fd2, &buf);
    if (buf[0] != 'H') return error.SeekReadMismatch;

    try posix.unlink(path);
}

fn fcntlTest(comptime lib: type) !void {
    const posix = lib.posix;

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    const original_flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

    _ = try posix.fcntl(sock, posix.F.SETFL, original_flags | nonblock_flag);
    const updated_flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    if ((updated_flags & nonblock_flag) == 0) return error.FcntlSetFlFailed;

    _ = try posix.fcntl(sock, posix.F.SETFL, original_flags);
    const restored_flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    if ((restored_flags & nonblock_flag) != (original_flags & nonblock_flag))
        return error.FcntlRestoreFailed;
}

fn getsockoptTest(comptime lib: type) !void {
    const posix = lib.posix;

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    var err_code: i32 = -1;
    try posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&err_code));
    if (err_code != 0) return error.GetSockOptErrorNotZero;
}

fn tcpTest(comptime lib: type) !void {
    const posix = lib.posix;

    const server = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(server);

    const enable: [4]u8 = @bitCast(@as(i32, 1));
    try posix.setsockopt(server, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable);

    var addr = loopbackSockAddr4(lib, 0);
    try posix.bind(server, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(server, @ptrCast(&bound_addr), &bound_len);
    const port = lib.mem.bigToNative(u16, bound_addr.port);

    try posix.listen(server, 1);

    var poll_fds = [_]posix.pollfd{.{
        .fd = server,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const client_thread = try lib.Thread.spawn(.{}, struct {
        fn connect(comptime p: type, comptime thread_lib: type, port_num: u16) void {
            const client = p.socket(p.AF.INET, p.SOCK.STREAM, 0) catch return;
            defer p.close(client);
            var dest = loopbackSockAddr4(thread_lib, port_num);
            p.connect(client, @ptrCast(&dest), @sizeOf(@TypeOf(dest))) catch return;
            _ = p.send(client, "hello", 0) catch return;
            var sink: [64]u8 = undefined;
            _ = p.recv(client, &sink, 0) catch return;
        }
    }.connect, .{ posix, lib, port });

    _ = try posix.poll(&poll_fds, 5000);

    var client_addr: posix.sockaddr.in = undefined;
    var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const accepted = try posix.accept(server, @ptrCast(&client_addr), &client_len, 0);
    defer posix.close(accepted);

    var buf: [64]u8 = undefined;
    const n = try posix.recv(accepted, &buf, 0);

    _ = try posix.send(accepted, buf[0..n], 0);

    try posix.shutdown(accepted, .send);

    client_thread.join();
}

fn udpTest(comptime lib: type) !void {
    const posix = lib.posix;

    const server = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(server);

    var addr = loopbackSockAddr4(lib, 0);
    try posix.bind(server, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(server, @ptrCast(&bound_addr), &bound_len);
    const port = lib.mem.bigToNative(u16, bound_addr.port);

    const client = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(client);

    var dest = loopbackSockAddr4(lib, port);
    _ = try posix.sendto(client, "udp-ping", 0, @ptrCast(&dest), @sizeOf(@TypeOf(dest)));

    var buf: [64]u8 = undefined;
    var src_addr: posix.sockaddr.in = undefined;
    var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    _ = try posix.recvfrom(server, &buf, 0, @ptrCast(&src_addr), &src_len);
}

fn loopbackSockAddr4(comptime lib: type, port: u16) lib.posix.sockaddr.in {
    const ip = [_]u8{ 127, 0, 0, 1 };
    return .{
        .port = lib.mem.nativeToBig(u16, port),
        .addr = @as(*align(1) const u32, @ptrCast(&ip)).*,
    };
}
