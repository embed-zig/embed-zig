const embed = @import("embed");
const io = @import("io");
const net_mod = @import("../../../../net.zig");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 3 * 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, run_allocator: lib.mem.Allocator) bool {
            _ = runner;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = Utils.Net;
                    const Http = Utils.Http;
                    const Thread = lib.Thread;
                    const test_spawn_config: lib.Thread.SpawnConfig = Utils.test_spawn_config;
                    const testing = struct {
                        pub var allocator: lib.mem.Allocator = undefined;
                        pub const expect = lib.testing.expect;
                        pub const expectEqual = lib.testing.expectEqual;
                        pub const expectEqualSlices = lib.testing.expectEqualSlices;
                        pub const expectEqualStrings = lib.testing.expectEqualStrings;
                        pub const expectError = lib.testing.expectError;
                    };
                    testing.allocator = a;

                    const ProxyProbeState = struct {
                        saw_connect: bool = false,
                        saw_probe: bool = false,
                    };

                    var target_ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfig());
                    defer target_ln.deinit();
                    const target_listener = try target_ln.as(Net.tls.Listener);
                    const target_port = try Utils.tlsListenerPort(target_ln, Net);
                    var target_result: ?anyerror = null;

                    var target_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.tls.Listener, result: *?anyerror) void {
                            var conn = listener.accept() catch |err| {
                                result.* = err;
                                return;
                            };
                            defer conn.deinit();

                            const typed = conn.as(Net.tls.ServerConn) catch {
                                result.* = error.TestUnexpectedResult;
                                return;
                            };
                            typed.handshake() catch |err| {
                                result.* = err;
                                return;
                            };

                            var req_buf: [4096]u8 = undefined;
                            const req_head = Utils.readRequestHead(conn, &req_buf) catch |err| {
                                result.* = err;
                                return;
                            };
                            if (!Utils.hasRequestLine(req_head, "GET /direct HTTP/1.1")) {
                                result.* = error.TestUnexpectedResult;
                                return;
                            }

                            io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\ndirect") catch |err| {
                                result.* = err;
                            };
                        }
                    }.run, .{ target_listener, &target_result });
                    defer target_thread.join();

                    var proxy_state = ProxyProbeState{};
                    var proxy_ln: net_mod.Listener = undefined;
                    var proxy_port: u16 = undefined;
                    var proxy_thread: Thread = undefined;
                    var proxy_cleaned = false;
                    {
                        var proxy_ln_local = try Net.listen(testing.allocator, .{ .address = Utils.addr4(0) });
                        errdefer proxy_ln_local.deinit();
                        const proxy_listener = try proxy_ln_local.as(Net.TcpListener);
                        proxy_port = try Utils.tcpListenerPort(proxy_ln_local, Net);
                        proxy_thread = try Thread.spawn(test_spawn_config, struct {
                            fn run(listener: *Net.TcpListener, state: *ProxyProbeState) void {
                                var conn = listener.accept() catch return;
                                defer conn.deinit();
                                conn.setReadTimeout(200);
                                var buf: [64]u8 = undefined;
                                const n = conn.read(&buf) catch return;
                                if (n == 0) return;
                                if (lib.mem.startsWith(u8, buf[0..n], "PING")) {
                                    state.saw_probe = true;
                                    return;
                                }
                                if (lib.mem.indexOf(u8, buf[0..n], "CONNECT ") != null) {
                                    state.saw_connect = true;
                                }
                            }
                        }.run, .{ proxy_listener, &proxy_state });
                        proxy_ln = proxy_ln_local;
                    }
                    defer if (!proxy_cleaned) {
                        proxy_ln.close();
                        proxy_thread.join();
                        proxy_ln.deinit();
                    };

                    var transport = try Http.Transport.init(testing.allocator, Utils.tlsTransportOptions());
                    defer transport.deinit();

                    const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/direct", .{target_port});
                    defer testing.allocator.free(raw_url);

                    var req = try Http.Request.init(testing.allocator, "GET", raw_url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try Utils.readBody(testing.allocator, resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("direct", body);

                    var probe = try Net.dial(testing.allocator, .tcp, Utils.addr4(proxy_port));
                    try io.writeAll(@TypeOf(probe), &probe, "PING");
                    probe.deinit();

                    proxy_thread.join();
                    proxy_ln.deinit();
                    proxy_cleaned = true;

                    try testing.expect(proxy_state.saw_probe);
                    try testing.expect(!proxy_state.saw_connect);
                    if (target_result) |err| return err;
                }
            };
            Body.call(run_allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
