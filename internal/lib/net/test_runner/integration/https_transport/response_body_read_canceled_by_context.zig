const stdz = @import("stdz");
const io = @import("io");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 3 * 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
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
                    const Context = @import("context").make(lib);
                    const testing = struct {
                        pub var allocator: lib.mem.Allocator = undefined;
                        pub const expect = lib.testing.expect;
                        pub const expectEqual = lib.testing.expectEqual;
                        pub const expectEqualSlices = lib.testing.expectEqualSlices;
                        pub const expectEqualStrings = lib.testing.expectEqualStrings;
                        pub const expectError = lib.testing.expectError;
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

                        fn waitTimeout(self: *@This(), timeout_ms: u32) bool {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            if (self.finished) return true;
                            self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * lib.time.ns_per_ms) catch {};
                            return self.finished;
                        }
                    };

                    var ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfig());
                    defer ln.deinit();

                    const listener_impl = try ln.as(Net.tls.Listener);
                    const port = try Utils.tlsListenerPort(ln, Net);
                    var server_result: ?anyerror = null;
                    var body_gate = BodyGate{};

                    var server_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.tls.Listener, result: *?anyerror, gate: *BodyGate) void {
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
                            if (!Utils.hasRequestLine(req_head, "GET /body-cancel HTTP/1.1")) {
                                result.* = error.TestUnexpectedResult;
                                return;
                            }

                            io.writeAll(
                                @TypeOf(conn),
                                &conn,
                                "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
                            ) catch |err| {
                                result.* = err;
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

                    const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/body-cancel", .{port});
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

                    try testing.expect(!read_task.waitTimeout(120));
                    ctx.cancel();
                    try testing.expect(read_task.waitTimeout(500));
                    read_thread.join();
                    read_joined = true;
                    try testing.expect(read_task.err != null);
                    try testing.expectEqual(error.Canceled, read_task.err.?);
                    if (server_result) |err| return err;
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
