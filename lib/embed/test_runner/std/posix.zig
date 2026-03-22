pub fn run(comptime lib: type) !void {
    try typeSurfaceTest(lib);
    try fileTest(lib);
    try seekTests(lib);
    try tcpTest(lib);
    try udpTest(lib);
}

fn typeSurfaceTest(comptime lib: type) !void {
    const log = lib.log.scoped(.posix);
    const posix = lib.posix;

    _ = posix.timeval;
    _ = posix.timespec;
    if (@sizeOf(posix.timespec) == 0) return error.TimespecTypeMissing;

    log.info("posix types: timeval+timespec present", .{});
}

fn fileTest(comptime lib: type) !void {
    const log = lib.log.scoped(.file);
    const posix = lib.posix;

    const dir_path = "/tmp/embed_test_runner";
    const file_path = dir_path ++ "/test.txt";

    posix.mkdir(dir_path, 0o755) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    log.info("mkdir ok", .{});

    const fd = try posix.open(file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const msg = "hello from test_runner!\n";
    const written = try posix.write(fd, msg);
    log.info("write {d} bytes", .{written});

    const pos = try posix.lseek_CUR_get(fd);
    log.info("lseek_CUR_get pos={}", .{pos});

    try posix.lseek_SET(fd, 0);
    posix.close(fd);

    const rfd = try posix.open(file_path, .{ .ACCMODE = .RDONLY }, 0);
    var buf: [128]u8 = undefined;
    const n = try posix.read(rfd, &buf);
    log.info("read: \"{s}\"", .{buf[0..n]});
    posix.close(rfd);

    try posix.unlink(file_path);
    log.info("file done", .{});
}

fn seekTests(comptime lib: type) !void {
    const log = lib.log.scoped(.seek);
    const posix = lib.posix;

    const path = "/tmp/embed_test_runner/seek_test.txt";
    const dir_path = "/tmp/embed_test_runner";
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
    log.info("lseek_SET(3) -> pos={}", .{pos});

    try posix.lseek_CUR(fd2, 2);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 5) return error.SeekCurFailed;
    log.info("lseek_CUR(+2) -> pos={}", .{pos});

    try posix.lseek_CUR(fd2, -1);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 4) return error.SeekCurNegFailed;
    log.info("lseek_CUR(-1) -> pos={}", .{pos});

    try posix.lseek_END(fd2, 0);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 10) return error.SeekEndFailed;
    log.info("lseek_END(0) -> pos={}", .{pos});

    try posix.lseek_END(fd2, -3);
    pos = try posix.lseek_CUR_get(fd2);
    if (pos != 7) return error.SeekEndNegFailed;
    log.info("lseek_END(-3) -> pos={}", .{pos});

    var buf: [1]u8 = undefined;
    _ = try posix.read(fd2, &buf);
    if (buf[0] != 'H') return error.SeekReadMismatch;
    log.info("read after seek = '{c}'", .{buf[0]});

    try posix.unlink(path);
    log.info("seek done", .{});
}

fn tcpTest(comptime lib: type) !void {
    const log = lib.log.scoped(.tcp);
    const posix = lib.posix;
    const Ip4Address = lib.net.Ip4Address;

    const server = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(server);
    log.info("tcp server fd={}", .{server});

    const enable: [4]u8 = @bitCast(@as(i32, 1));
    try posix.setsockopt(server, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable);

    const addr = Ip4Address.init(.{ 127, 0, 0, 1 }, 0);
    try posix.bind(server, @ptrCast(&addr.sa), @sizeOf(@TypeOf(addr.sa)));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(server, @ptrCast(&bound_addr), &bound_len);
    const port = lib.mem.bigToNative(u16, bound_addr.port);
    log.info("bound to port {}", .{port});

    try posix.listen(server, 1);
    log.info("listening", .{});

    var poll_fds = [_]posix.pollfd{.{
        .fd = server,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const client_thread = try lib.Thread.spawn(.{}, struct {
        fn connect(comptime p: type, comptime net: type, port_num: u16) void {
            const client = p.socket(p.AF.INET, p.SOCK.STREAM, 0) catch return;
            defer p.close(client);
            const dest = net.Ip4Address.init(.{ 127, 0, 0, 1 }, port_num);
            p.connect(client, @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa))) catch return;
            _ = p.send(client, "hello", 0) catch return;
            var sink: [64]u8 = undefined;
            _ = p.recv(client, &sink, 0) catch return;
        }
    }.connect, .{ posix, lib.net, port });

    const poll_ready = try posix.poll(&poll_fds, 5000);
    log.info("poll ready={}", .{poll_ready});

    var client_addr: posix.sockaddr.in = undefined;
    var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const accepted = try posix.accept(server, @ptrCast(&client_addr), &client_len, 0);
    defer posix.close(accepted);
    log.info("accepted fd={}", .{accepted});

    var buf: [64]u8 = undefined;
    const n = try posix.recv(accepted, &buf, 0);
    log.info("recv: \"{s}\"", .{buf[0..n]});

    _ = try posix.send(accepted, buf[0..n], 0);
    log.info("echoed {d} bytes", .{n});

    try posix.shutdown(accepted, .send);
    log.info("shutdown send", .{});

    client_thread.join();
    log.info("tcp done", .{});
}

fn udpTest(comptime lib: type) !void {
    const log = lib.log.scoped(.udp);
    const posix = lib.posix;
    const Ip4Address = lib.net.Ip4Address;

    const server = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(server);

    const addr = Ip4Address.init(.{ 127, 0, 0, 1 }, 0);
    try posix.bind(server, @ptrCast(&addr.sa), @sizeOf(@TypeOf(addr.sa)));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(server, @ptrCast(&bound_addr), &bound_len);
    const port = lib.mem.bigToNative(u16, bound_addr.port);
    log.info("udp bound to port {}", .{port});

    const client = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(client);

    const dest = Ip4Address.init(.{ 127, 0, 0, 1 }, port);
    _ = try posix.sendto(client, "udp-ping", 0, @ptrCast(&dest.sa), @sizeOf(@TypeOf(dest.sa)));
    log.info("sendto ok", .{});

    var buf: [64]u8 = undefined;
    var src_addr: posix.sockaddr.in = undefined;
    var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const n = try posix.recvfrom(server, &buf, 0, @ptrCast(&src_addr), &src_len);
    log.info("recvfrom: \"{s}\"", .{buf[0..n]});

    log.info("udp done", .{});
}
