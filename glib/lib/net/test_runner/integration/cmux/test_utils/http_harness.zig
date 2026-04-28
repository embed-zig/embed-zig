const AddrPort = @import("../../../../netip/AddrPort.zig");

pub const stream_read_total_bytes: usize = 2048;
pub const stream_read_chunk_bytes: usize = 256;
pub const stream_write_total_bytes: usize = 400;
pub const stream_write_chunk_bytes: usize = 100;

pub fn HarnessOptions(comptime std: type) type {
    _ = std;
    return struct {
        max_accept_queue: usize = 8,
        read_buffer_size: usize = 1024,
        write_buffer_size: usize = 1024,
    };
}

pub fn dialHttpChannel(
    comptime std: type,
    comptime net: type,
    cmux: *net.Cmux,
    dlci: u16,
) !net.Conn {
    _ = std;
    return cmux.dial(dlci);
}

pub fn withCmuxHttpServer(
    comptime std: type,
    comptime net: type,
    alloc: std.mem.Allocator,
    body: *const fn (*net.Cmux, std.mem.Allocator) anyerror!void,
) !void {
    return withCmuxHttpServerOptions(std, net, alloc, .{}, body);
}

pub fn withCmuxHttpServerOptions(
    comptime std: type,
    comptime net: type,
    alloc: std.mem.Allocator,
    harness_options: HarnessOptions(std),
    body: *const fn (*net.Cmux, std.mem.Allocator) anyerror!void,
) !void {
    const thread = std.Thread;

    const test_spawn_config: thread.SpawnConfig = .{ .stack_size = 1024 * 1024 };

    var tcp_listener = try net.TcpListener.init(alloc, .{ .address = addr4(0) });
    defer tcp_listener.deinit();
    const tcp_impl = try tcp_listener.as(net.TcpListener);
    try tcp_impl.listen();
    const port = try tcp_impl.port();

    var ready: gate(std) = .{};
    var shared: serverShared(std) = .{};

    var server_thread = try thread.spawn(test_spawn_config, struct {
        fn exec(
            alloc2: std.mem.Allocator,
            ln: net.Listener,
            shared_ptr: *serverShared(std),
            ready_ptr: *gate(std),
            spawn_cfg: std.Thread.SpawnConfig,
            harness_options_arg: HarnessOptions(std),
        ) void {
            serverThreadMain(std, net, alloc2, ln, shared_ptr, ready_ptr, spawn_cfg, harness_options_arg);
        }
    }.exec, .{ alloc, tcp_listener, &shared, &ready, test_spawn_config, harness_options });
    defer {
        tcp_listener.close();
        server_thread.join();
    }

    const client_tcp = try net.dial(alloc, .tcp, addr4(port));
    ready.wait();

    shared.mutex.lock();
    const setup_err = shared.serve_err;
    shared.mutex.unlock();
    if (setup_err) |err| {
        return err;
    }

    var client_cmux = try net.Cmux.init(alloc, client_tcp, .{
        .role = .initiator,
        .max_accept_queue = harness_options.max_accept_queue,
        .read_buffer_size = harness_options.read_buffer_size,
        .write_buffer_size = harness_options.write_buffer_size,
    });
    defer client_cmux.deinit();

    try body(client_cmux, alloc);

    shared.mutex.lock();
    const final_err = shared.serve_err;
    shared.mutex.unlock();
    if (final_err) |err| {
        if (err != error.ServerClosed) return err;
    }
}

pub fn registerRoutes(comptime std: type, comptime net: type, server: *httpServer(net)) !void {
    try registerEchoRoute(std, net, server);
    try registerPingRoute(std, net, server);
    try registerStreamReadRoute(std, net, server);
    try registerStreamWriteRoute(std, net, server);
}

fn addr4(port: u16) AddrPort {
    return AddrPort.from4(.{ 127, 0, 0, 1 }, port);
}

fn httpServer(comptime net: type) type {
    return net.http.Server;
}

fn serverShared(comptime std: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        serve_err: ?anyerror = null,
    };
}

fn gate(comptime std: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        open: bool = false,

        fn signal(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.open = true;
            self.cond.broadcast();
        }

        fn wait(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.open) self.cond.wait(&self.mutex);
        }
    };
}

fn serverThreadMain(
    comptime std: type,
    comptime net: type,
    alloc: std.mem.Allocator,
    tcp_listener: net.Listener,
    shared: *serverShared(std),
    ready: *gate(std),
    test_spawn_config: std.Thread.SpawnConfig,
    harness_options: HarnessOptions(std),
) void {
    const http = net.http;
    const cmux_type = net.Cmux;

    const tcp_bearer = tcp_listener.accept() catch |err| {
        shared.mutex.lock();
        shared.serve_err = err;
        shared.mutex.unlock();
        ready.signal();
        return;
    };

    var cmux = cmux_type.init(alloc, tcp_bearer, .{
        .role = .responder,
        .max_accept_queue = harness_options.max_accept_queue,
        .read_buffer_size = harness_options.read_buffer_size,
        .write_buffer_size = harness_options.write_buffer_size,
    }) catch |err| {
        shared.mutex.lock();
        shared.serve_err = err;
        shared.mutex.unlock();
        ready.signal();
        return;
    };
    defer cmux.deinit();

    var server = http.Server.init(alloc, .{
        .spawn_config = test_spawn_config,
    }) catch |err| {
        shared.mutex.lock();
        shared.serve_err = err;
        shared.mutex.unlock();
        ready.signal();
        return;
    };
    defer server.deinit();

    registerRoutes(std, net, &server) catch |err| {
        shared.mutex.lock();
        shared.serve_err = err;
        shared.mutex.unlock();
        ready.signal();
        return;
    };

    ready.signal();

    server.serve(cmux.listener) catch |err| {
        shared.mutex.lock();
        if (shared.serve_err == null) shared.serve_err = err;
        shared.mutex.unlock();
    };
}

fn registerEchoRoute(comptime std: type, comptime net: type, server: *httpServer(net)) !void {
    const http = net.http;

    try server.handleFunc("/echo", struct {
        fn run(rw: *http.ResponseWriter, req: *http.Request) void {
            const q = req.url.raw_query;
            const prefix = "id=";
            if (!std.mem.startsWith(u8, q, prefix)) return;

            var id_slice = q[prefix.len..];
            if (std.mem.indexOfScalar(u8, id_slice, '&')) |i| id_slice = id_slice[0..i];

            var body_buf: [64]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "echo:{s}", .{id_slice}) catch return;
            var cl_buf: [16]u8 = undefined;
            const cl = std.fmt.bufPrint(&cl_buf, "{d}", .{body.len}) catch return;
            rw.setHeader(http.Header.content_length, cl) catch return;
            _ = rw.write(body) catch {};
        }
    }.run);
}

fn registerPingRoute(comptime std: type, comptime net: type, server: *httpServer(net)) !void {
    _ = std;
    const http = net.http;

    try server.handleFunc("/ping", struct {
        fn run(rw: *http.ResponseWriter, _: *http.Request) void {
            rw.setHeader(http.Header.content_length, "4") catch return;
            _ = rw.write("pong") catch {};
        }
    }.run);
}

fn registerStreamReadRoute(comptime std: type, comptime net: type, server: *httpServer(net)) !void {
    const http = net.http;
    const thread = std.Thread;

    try server.handleFunc("/stream/read", struct {
        fn run(rw: *http.ResponseWriter, _: *http.Request) void {
            var cl_buf: [16]u8 = undefined;
            const cl = std.fmt.bufPrint(&cl_buf, "{d}", .{stream_read_total_bytes}) catch return;
            rw.setHeader(http.Header.content_length, cl) catch return;

            var chunk: [stream_read_chunk_bytes]u8 = undefined;
            @memset(chunk[0..], 'r');

            var sent: usize = 0;
            while (sent < stream_read_total_bytes) : (sent += chunk.len) {
                _ = rw.write(chunk[0..]) catch return;
                thread.sleep(@intCast(2 * net.time.duration.MilliSecond));
            }
        }
    }.run);
}

fn registerStreamWriteRoute(comptime std: type, comptime net: type, server: *httpServer(net)) !void {
    const http = net.http;

    try server.handleFunc("/stream/write", struct {
        fn run(rw: *http.ResponseWriter, req: *http.Request) void {
            var total_bytes: usize = 0;
            var read_calls: usize = 0;

            if (req.body_reader) |*body| {
                var buf: [64]u8 = undefined;
                while (true) {
                    const n = body.read(&buf) catch return;
                    if (n == 0) break;
                    total_bytes += n;
                    read_calls += 1;
                }
            }

            var body_buf: [64]u8 = undefined;
            const body = std.fmt.bufPrint(
                &body_buf,
                "bytes={d} reads={d}",
                .{ total_bytes, read_calls },
            ) catch return;
            var cl_buf: [16]u8 = undefined;
            const cl = std.fmt.bufPrint(&cl_buf, "{d}", .{body.len}) catch return;
            rw.setHeader(http.Header.content_length, cl) catch return;
            _ = rw.write(body) catch {};
        }
    }.run);
}
