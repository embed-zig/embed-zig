const stdz = @import("stdz");
const io = @import("io");
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
                    const ThreadResult = thread_sync.ThreadResult(std);
                    const test_spawn_config: std.Thread.SpawnConfig = Utils.test_spawn_config;
                    const Context = @import("context").make(std, net.time);
                    const testing = struct {
                        pub var allocator: std.mem.Allocator = undefined;
                        pub const expect = std.testing.expect;
                        pub const expectEqual = std.testing.expectEqual;
                        pub const expectEqualSlices = std.testing.expectEqualSlices;
                        pub const expectEqualStrings = std.testing.expectEqualStrings;
                        pub const expectError = std.testing.expectError;
                    };
                    testing.allocator = a;

                    const BodyGate = struct {
                        mutex: Thread.Mutex = .{},
                        cond: Thread.Condition = .{},
                        released: bool = false,

                        fn wait(self: *@This()) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            while (!self.released) self.cond.wait(&self.mutex);
                        }

                        fn release(self: *@This()) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            self.released = true;
                            self.cond.broadcast();
                        }
                    };
                    const BodyReadTask = struct {
                        mutex: Thread.Mutex = .{},
                        cond: Thread.Condition = .{},
                        resp: *Http.Response,
                        err: ?anyerror = null,
                        bytes: [4]u8 = undefined,
                        len: usize = 0,
                        finished: bool = false,

                        fn run(self: *@This()) void {
                            defer {
                                self.mutex.lock();
                                self.finished = true;
                                self.cond.broadcast();
                                self.mutex.unlock();
                            }

                            const body = self.resp.body() orelse {
                                self.err = error.TestUnexpectedResult;
                                return;
                            };
                            self.len = body.read(&self.bytes) catch |err| {
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

                    var ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfig());
                    defer ln.deinit();

                    const listener_impl = try ln.as(Net.tls.Listener);
                    const port = try Utils.tlsListenerPort(ln, Net);
                    var server_result = ThreadResult{};
                    var body_gate = BodyGate{};

                    var server_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.tls.Listener, result: *ThreadResult, gate: *BodyGate) void {
                            var thread_err: ?anyerror = null;
                            defer result.finish(thread_err);

                            var conn = listener.accept() catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer conn.deinit();

                            const typed = conn.as(Net.tls.ServerConn) catch {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            };
                            typed.handshake() catch |err| {
                                thread_err = err;
                                return;
                            };

                            var req_buf: [4096]u8 = undefined;
                            const req_head = Utils.readRequestHead(conn, &req_buf) catch |err| {
                                thread_err = err;
                                return;
                            };
                            if (!Utils.hasRequestLine(req_head, "GET /body-cancel HTTP/1.1")) {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            }

                            io.writeAll(
                                @TypeOf(conn),
                                &conn,
                                "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
                            ) catch |err| {
                                thread_err = err;
                                return;
                            };
                            gate.wait();
                            io.writeAll(@TypeOf(conn), &conn, "late") catch {};
                        }
                    }.run, .{ listener_impl, &server_result, &body_gate });
                    defer server_thread.join();

                    var ctx_api = try Context.init(testing.allocator);
                    defer ctx_api.deinit();
                    var ctx = try ctx_api.withCancel(ctx_api.background());
                    defer ctx.deinit();

                    var transport = try Http.Transport.init(testing.allocator, Utils.tlsTransportOptions());
                    defer transport.deinit();

                    const raw_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/body-cancel", .{port});
                    defer testing.allocator.free(raw_url);

                    var req = try Http.Request.init(testing.allocator, "GET", raw_url);
                    req = req.withContext(ctx);

                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    var read_task = BodyReadTask{ .resp = &resp };
                    var read_thread = try Thread.spawn(test_spawn_config, BodyReadTask.run, .{&read_task});
                    var read_joined = false;
                    defer if (!read_joined) read_thread.join();
                    defer body_gate.release();

                    try testing.expect(!read_task.waitTimeout(120 * net.time.duration.MilliSecond));
                    ctx.cancel();
                    try testing.expect(read_task.waitTimeout(500 * net.time.duration.MilliSecond));
                    read_thread.join();
                    read_joined = true;
                    try testing.expect(read_task.err != null);
                    try testing.expectEqual(error.Canceled, read_task.err.?);
                    body_gate.release();
                    if (server_result.wait()) |err| return err;
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
