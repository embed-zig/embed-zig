const host_std = @import("std");
const stdz = @import("stdz");
const testing_mod = @import("testing");

pub fn make(comptime std: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("type_surface", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try typeSurfaceTest(std);
                }
            }.run));
            t.run("file", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try fileTest(std);
                }
            }.run));
            t.run("seek", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try seekTests(std);
                }
            }.run));
            t.run("fcntl", testing_mod.TestRunner.fromFn(std, 16 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try fcntlTest(std);
                }
            }.run));
            t.run("getsockopt", testing_mod.TestRunner.fromFn(std, 16 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try getsockoptTest(std);
                }
            }.run));
            t.run("tcp", testing_mod.TestRunner.fromFn(std, 64 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try tcpTest(std);
                }
            }.run));
            t.run("udp", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try udpTest(std);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn typeSurfaceTest(comptime std: type) !void {
    const posix = std.posix;

    _ = posix.timeval;
    _ = posix.timespec;
    if (@sizeOf(posix.timespec) == 0) return error.TimespecTypeMissing;
}

fn fileTest(comptime std: type) !void {
    const posix = std.posix;

    const dir_path = "/tmp/stdz_test_runner";
    const file_path = dir_path ++ "/test.txt";

    posix.mkdir(dir_path, 0o755) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

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

fn seekTests(comptime std: type) !void {
    const posix = std.posix;

    const path = "/tmp/stdz_test_runner/seek_test.txt";
    const dir_path = "/tmp/stdz_test_runner";
    posix.mkdir(dir_path, 0o755) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

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

fn fcntlTest(comptime std: type) !void {
    const posix = std.posix;

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

fn getsockoptTest(comptime std: type) !void {
    const posix = std.posix;

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    var err_code: i32 = -1;
    try posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, host_std.mem.asBytes(&err_code));
    if (err_code != 0) return error.GetSockOptErrorNotZero;
}

fn tcpTest(comptime std: type) !void {
    const posix = std.posix;

    const server = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(server);

    const enable: [4]u8 = @bitCast(@as(i32, 1));
    try posix.setsockopt(server, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable);

    var addr = loopbackSockAddr4(std, 0);
    try posix.bind(server, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(server, @ptrCast(&bound_addr), &bound_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    try posix.listen(server, 1);

    var poll_fds = [_]posix.pollfd{.{
        .fd = server,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const client_thread = try std.Thread.spawn(.{}, struct {
        fn connect(comptime p: type, comptime thread_lib: type, port_num: u16) void {
            const client = p.socket(p.AF.INET, p.SOCK.STREAM, 0) catch return;
            defer p.close(client);
            var dest = loopbackSockAddr4(thread_lib, port_num);
            p.connect(client, @ptrCast(&dest), @sizeOf(@TypeOf(dest))) catch return;
            _ = p.send(client, "hello", 0) catch return;
            var sink: [64]u8 = undefined;
            _ = p.recv(client, &sink, 0) catch return;
        }
    }.connect, .{ posix, std, port });

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

fn udpTest(comptime std: type) !void {
    const posix = std.posix;

    const server = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(server);

    var addr = loopbackSockAddr4(std, 0);
    try posix.bind(server, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(server, @ptrCast(&bound_addr), &bound_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    const client = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(client);

    var dest = loopbackSockAddr4(std, port);
    _ = try posix.sendto(client, "udp-ping", 0, @ptrCast(&dest), @sizeOf(@TypeOf(dest)));

    var buf: [64]u8 = undefined;
    var src_addr: posix.sockaddr.in = undefined;
    var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    _ = try posix.recvfrom(server, &buf, 0, @ptrCast(&src_addr), &src_len);
}

fn loopbackSockAddr4(comptime std: type, port: u16) std.posix.sockaddr.in {
    const ip = [_]u8{ 127, 0, 0, 1 };
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @as(*align(1) const u32, @ptrCast(&ip)).*,
    };
}
