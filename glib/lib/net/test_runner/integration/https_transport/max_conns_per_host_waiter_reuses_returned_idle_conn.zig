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

                    const RoundTripTask = struct {
                        mutex: Thread.Mutex = .{},
                        cond: Thread.Condition = .{},
                        transport: *Http.Transport,
                        req: *Http.Request,
                        resp: ?Http.Response = null,
                        err: ?anyerror = null,
                        finished: bool = false,

                        fn run(self: *@This()) void {
                            defer {
                                self.mutex.lock();
                                self.finished = true;
                                self.cond.broadcast();
                                self.mutex.unlock();
                            }
                            self.resp = self.transport.roundTrip(self.req) catch |err| {
                                self.err = err;
                                return;
                            };
                        }

                        fn waitTimeout(self: *@This(), timeout: net.time.duration.Duration) bool {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            if (self.finished) return true;
                            self.cond.timedWait(&self.mutex, @intCast(timeout)) catch {};
                            return self.finished;
                        }
                    };

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

                            _ = Utils.serveKeepAliveRequest(conn, "GET /cap-reuse-1 HTTP/1.1", "first over tls", false) catch |err| {
                                thread_err = err;
                                return;
                            };

                            conn.setReadDeadline(net.time.instant.add(net.time.instant.now(), 200 * net.time.duration.MilliSecond));
                            const reused = Utils.serveKeepAliveRequest(conn, "GET /cap-reuse-2 HTTP/1.1", "second over tls", true) catch |err| switch (err) {
                                error.EndOfStream,
                                error.TimedOut,
                                error.Unexpected,
                                => false,
                                else => {
                                    thread_err = err;
                                    return;
                                },
                            };
                            if (reused) snapshot.reused = true;
                        }
                    }.run, .{ listener_impl, &server_state });
                    defer server_thread.join();

                    var transport = try Http.Transport.init(testing.allocator, .{
                        .tls_client_config = Utils.tlsTransportOptions().tls_client_config,
                        .max_conns_per_host = 1,
                    });
                    defer transport.deinit();

                    const first_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/cap-reuse-1", .{port});
                    defer testing.allocator.free(first_url);
                    var req1 = try Http.Request.init(testing.allocator, "GET", first_url);
                    var resp1 = try transport.roundTrip(&req1);
                    defer resp1.deinit();
                    const body1 = resp1.body() orelse return error.TestUnexpectedResult;
                    var first: [1]u8 = undefined;
                    try testing.expectEqual(@as(usize, 1), try body1.read(&first));

                    const second_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/cap-reuse-2", .{port});
                    defer testing.allocator.free(second_url);
                    var req2 = try Http.Request.init(testing.allocator, "GET", second_url);
                    var task = RoundTripTask{
                        .transport = &transport,
                        .req = &req2,
                    };
                    var thread = try Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                    var joined = false;
                    defer if (!joined) thread.join();

                    try testing.expect(!task.waitTimeout(120 * net.time.duration.MilliSecond));
                    const rest = try Utils.readBody(testing.allocator, resp1);
                    defer testing.allocator.free(rest);
                    thread.join();
                    joined = true;

                    if (task.err) |err| return err;
                    var resp2 = task.resp orelse return error.TestUnexpectedResult;
                    defer resp2.deinit();

                    const body2 = try Utils.readBody(testing.allocator, resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("second over tls", body2);
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
