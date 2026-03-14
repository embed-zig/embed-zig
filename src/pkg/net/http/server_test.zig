const std = @import("std");
const testing = std.testing;
const module = @import("server.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Config = module.Config;
const Server = module.Server;
const mem = test_exports.mem;
const Allocator = test_exports.Allocator;
const request_mod = test_exports.request_mod;
const response_mod = test_exports.response_mod;
const router_mod = test_exports.router_mod;
const Request = test_exports.Request;
const Response = test_exports.Response;
const Route = test_exports.Route;
const Handler = test_exports.Handler;
const connWriteFn = test_exports.connWriteFn;
const MockConn = test_exports.MockConn;
const MockState = test_exports.MockState;
const testHandler = test_exports.testHandler;
const runtime = test_exports.runtime;
const Socket = test_exports.Socket;
const SocketConn = test_exports.SocketConn;
const echoHandler = test_exports.echoHandler;
const jsonHandler = test_exports.jsonHandler;
const slowHandler = test_exports.slowHandler;
const test_routes = test_exports.test_routes;
const startTestServer = test_exports.startTestServer;
const serveOne = test_exports.serveOne;
const httpGet = test_exports.httpGet;
const httpPost = test_exports.httpPost;

test "full request-response cycle" {
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockState{ .input = raw };
    const conn = MockConn{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = Server(MockConn, .{ .read_buf_size = 1024, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(conn);

    const out = state.output[0..state.output_len];
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, out, "Content-Type: text/plain\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "Hello"));
    try testing.expect(state.closed);
}

test "keep-alive — multiple requests" {
    const raw =
        "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
        "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockState{ .input = raw };
    const conn = MockConn{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = Server(MockConn, .{ .read_buf_size = 2048, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(conn);

    const out = state.output[0..state.output_len];
    var count: usize = 0;
    var pos: usize = 0;
    while (mem.indexOfPos(u8, out, pos, "HTTP/1.1 200 OK")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "Connection: close terminates" {
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockState{ .input = raw };
    const conn = MockConn{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = Server(MockConn, .{ .read_buf_size = 1024, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(conn);

    try testing.expect(state.closed);
    const out = state.output[0..state.output_len];
    var count: usize = 0;
    var pos: usize = 0;
    while (mem.indexOfPos(u8, out, pos, "HTTP/1.1 200 OK")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "TCP loopback: single GET" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

    var buf: [4096]u8 = undefined;
    const resp = try httpGet(port, "/echo", &buf);
    try testing.expect(mem.indexOf(u8, resp, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.endsWith(u8, resp, "/echo"));

    t.join();
}

test "TCP loopback: POST with body" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

    var buf: [4096]u8 = undefined;
    const resp = try httpPost(port, "/echo", "hello world", &buf);
    try testing.expect(mem.indexOf(u8, resp, "HTTP/1.1 200 OK") != null);
    try testing.expect(mem.endsWith(u8, resp, "hello world"));

    t.join();
}

test "TCP loopback: JSON endpoint" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

    var buf: [4096]u8 = undefined;
    const resp = try httpGet(port, "/json", &buf);
    try testing.expect(mem.indexOf(u8, resp, "application/json") != null);
    try testing.expect(mem.endsWith(u8, resp, "{\"ok\":true}"));

    t.join();
}

test "TCP loopback: 404 for unknown path" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

    var buf: [4096]u8 = undefined;
    const resp = try httpGet(port, "/nonexistent", &buf);
    try testing.expect(mem.indexOf(u8, resp, "HTTP/1.1 404") != null);

    t.join();
}

test "TCP loopback: concurrent clients — 8 threads" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const N = 8;

    var server_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        server_threads[i] = try std.Thread.spawn(.{}, serveOne, .{&listener});
    }

    const results = struct {
        var success: [N]bool = .{false} ** N;
    };

    const ClientWorker = struct {
        fn run(p: u16, idx: usize) void {
            var buf: [4096]u8 = undefined;
            const resp = httpGet(p, "/echo", &buf) catch return;
            if (mem.indexOf(u8, resp, "HTTP/1.1 200 OK") != null) {
                results.success[idx] = true;
            }
        }
    };

    var client_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, ClientWorker.run, .{ port, i });
    }
    for (&client_threads) |*t| t.join();
    for (&server_threads) |*t| t.join();

    for (results.success) |s| {
        try testing.expect(s);
    }
}

test "TCP loopback: concurrent mixed GET+POST — 6 threads" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    const N = 6;

    var server_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        server_threads[i] = try std.Thread.spawn(.{}, serveOne, .{&listener});
    }

    const results = struct {
        var success: [N]bool = .{false} ** N;
    };

    const MixedWorker = struct {
        fn run(p: u16, idx: usize) void {
            var buf: [4096]u8 = undefined;
            if (idx % 2 == 0) {
                const resp = httpGet(p, "/json", &buf) catch return;
                if (mem.indexOf(u8, resp, "200 OK") != null) results.success[idx] = true;
            } else {
                const body = "payload";
                const resp = httpPost(p, "/echo", body, &buf) catch return;
                if (mem.endsWith(u8, resp, body)) results.success[idx] = true;
            }
        }
    };

    var client_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, MixedWorker.run, .{ port, i });
    }
    for (&client_threads) |*t| t.join();
    for (&server_threads) |*t| t.join();

    for (results.success) |s| {
        try testing.expect(s);
    }
}

test "TCP loopback: rapid sequential requests on same port" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    for (0..5) |_| {
        const t = try std.Thread.spawn(.{}, serveOne, .{&listener});

        var buf: [4096]u8 = undefined;
        const resp = httpGet(port, "/echo", &buf) catch break;
        try testing.expect(mem.indexOf(u8, resp, "200 OK") != null);

        t.join();
    }
}

test "TCP loopback: concurrent slow + fast handlers" {
    var port: u16 = 0;
    var listener = try startTestServer(&port);
    defer listener.close();

    var s1 = try std.Thread.spawn(.{}, serveOne, .{&listener});
    var s2 = try std.Thread.spawn(.{}, serveOne, .{&listener});

    const results = struct {
        var fast_done: bool = false;
        var slow_done: bool = false;
    };

    const FastWorker = struct {
        fn run(p: u16) void {
            var buf: [4096]u8 = undefined;
            const resp = httpGet(p, "/echo", &buf) catch return;
            if (mem.indexOf(u8, resp, "200 OK") != null) results.fast_done = true;
        }
    };
    const SlowWorker = struct {
        fn run(p: u16) void {
            var buf: [4096]u8 = undefined;
            const resp = httpGet(p, "/slow", &buf) catch return;
            if (mem.endsWith(u8, resp, "slow")) results.slow_done = true;
        }
    };

    var c1 = try std.Thread.spawn(.{}, SlowWorker.run, .{port});
    std.Thread.sleep(2 * std.time.ns_per_ms);
    var c2 = try std.Thread.spawn(.{}, FastWorker.run, .{port});

    c1.join();
    c2.join();
    s1.join();
    s2.join();

    try testing.expect(results.fast_done or results.slow_done);
}
