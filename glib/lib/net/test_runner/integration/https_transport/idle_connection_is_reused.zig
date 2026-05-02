const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");
const thread_sync = @import("../../test_utils/thread_sync.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Utils = test_utils.make(std, net);

    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 3 * 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, run_allocator: std.mem.Allocator) bool {
            _ = runner;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    const Net = Utils.Net;
                    const Http = Utils.Http;
                    const Thread = std.Thread;
                    const test_spawn_config: std.Thread.SpawnConfig = Utils.test_spawn_config;
                    const testing = struct {
                        pub var allocator: std.mem.Allocator = undefined;
                        pub const expect = std.testing.expect;
                        pub const expectEqual = std.testing.expectEqual;
                        pub const expectEqualSlices = std.testing.expectEqualSlices;
                        pub const expectEqualStrings = std.testing.expectEqualStrings;
                        pub const expectError = std.testing.expectError;
                    };
                    testing.allocator = a;

                    const ReuseState = struct {
                        reused: bool = false,
                        accepted: usize = 0,
                    };
                    const ThreadSnapshot = thread_sync.ThreadSnapshot(std, ReuseState);

                    var server_state = ThreadSnapshot{};
                    var ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfig());
                    defer ln.deinit();

                    const listener_impl = try ln.as(Net.tls.Listener);
                    const port = try Utils.tlsListenerPort(ln, Net);

                    var server_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.tls.Listener, result: *ThreadSnapshot) void {
                            var snapshot = ReuseState{};
                            var thread_err: ?anyerror = null;
                            defer result.finish(snapshot, thread_err);

                            var conn = listener.accept() catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer conn.deinit();
                            snapshot.accepted += 1;

                            const typed = conn.as(Net.tls.ServerConn) catch {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            };
                            typed.handshake() catch |err| {
                                thread_err = err;
                                return;
                            };

                            _ = Utils.serveKeepAliveRequest(conn, "GET /first HTTP/1.1", "first over tls", false) catch |err| {
                                thread_err = err;
                                return;
                            };

                            conn.setReadDeadline(net.time.instant.add(net.time.instant.now(), 150 * net.time.duration.MilliSecond));
                            const reused = Utils.serveKeepAliveRequest(conn, "GET /second HTTP/1.1", "second over tls", true) catch |err| switch (err) {
                                error.EndOfStream,
                                error.TimedOut,
                                error.Unexpected,
                                => false,
                                else => {
                                    thread_err = err;
                                    return;
                                },
                            };
                            if (reused) {
                                snapshot.reused = true;
                                return;
                            }

                            var second_conn = listener.accept() catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer second_conn.deinit();
                            snapshot.accepted += 1;

                            const second_typed = second_conn.as(Net.tls.ServerConn) catch {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            };
                            second_typed.handshake() catch |err| {
                                thread_err = err;
                                return;
                            };

                            _ = Utils.serveKeepAliveRequest(second_conn, "GET /second HTTP/1.1", "second over tls", true) catch |err| {
                                thread_err = err;
                            };
                        }
                    }.run, .{ listener_impl, &server_state });
                    defer server_thread.join();

                    var transport = try Http.Transport.init(testing.allocator, Utils.tlsTransportOptions());
                    defer transport.deinit();

                    const first_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/first", .{port});
                    defer testing.allocator.free(first_url);
                    var req1 = try Http.Request.init(testing.allocator, "GET", first_url);
                    var resp1 = try transport.roundTrip(&req1);
                    const body1 = try Utils.readBody(testing.allocator, resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("first over tls", body1);
                    resp1.deinit();

                    const second_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/second", .{port});
                    defer testing.allocator.free(second_url);
                    var req2 = try Http.Request.init(testing.allocator, "GET", second_url);
                    var resp2 = try transport.roundTrip(&req2);
                    const tls_state2 = resp2.tls orelse return error.TestUnexpectedResult;
                    try testing.expectEqual(@as(u16, @intFromEnum(Net.tls.ProtocolVersion.tls_1_3)), tls_state2.version);
                    try testing.expect(tls_state2.cipher_suite != 0);
                    const body2 = try Utils.readBody(testing.allocator, resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("second over tls", body2);
                    resp2.deinit();

                    const snapshot = try server_state.wait();
                    try testing.expect(snapshot.reused);
                    try testing.expectEqual(@as(usize, 1), snapshot.accepted);
                }
            };
            Body.call(run_allocator) catch |err| {
                t.logFatal(@errorName(err));
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
