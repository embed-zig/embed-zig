const stdz = @import("stdz");
const context_mod = @import("context");
const io = @import("io");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, run_allocator: lib.mem.Allocator) bool {
            _ = runner;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Http = Utils.Http;
                    const testing = struct {
                        pub var allocator: lib.mem.Allocator = undefined;
                        pub const expect = lib.testing.expect;
                        pub const expectEqual = lib.testing.expectEqual;
                        pub const expectEqualStrings = lib.testing.expectEqualStrings;
                        pub const expectError = lib.testing.expectError;
                    };
                    testing.allocator = a;
                    const test_spawn_config: lib.Thread.SpawnConfig = .{};

                    const Mutex = lib.Thread.Mutex;
                    const Condition = lib.Thread.Condition;

                    const RoundTripTask = struct {
                        mutex: Mutex = .{},
                        cond: Condition = .{},
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

                        fn waitTimeout(self: *@This(), timeout_ms: u32) bool {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            if (self.finished) return true;
                            self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * lib.time.ns_per_ms) catch {};
                            return self.finished;
                        }
                    };
                    const State = struct {};
                    try Utils.withServerState(testing.allocator, 
                        State{},
                        struct {
                            fn run(conn: net_mod.Conn, _: *State) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "GET /max-cancel-1 HTTP/1.1"));
                                io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello") catch {};
                                c.setReadTimeout(120);
                                _ = c.read(&req_buf) catch |err| switch (err) {
                                    error.TimedOut, error.EndOfStream => return,
                                    else => return err,
                                };
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, _: *State) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{
                                    .max_conns_per_host = 1,
                                });
                                defer transport.deinit();

                                const Context = context_mod.make(lib);
                                var ctx_api = try Context.init(testing.allocator);
                                defer ctx_api.deinit();

                                const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-cancel-1", .{port});
                                defer testing.allocator.free(url1);
                                const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-cancel-2", .{port});
                                defer testing.allocator.free(url2);

                                var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                                var resp1 = try transport.roundTrip(&req1);
                                defer resp1.deinit();

                                var cancel_ctx = try ctx_api.withCancel(ctx_api.background());
                                defer cancel_ctx.deinit();
                                var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                                req2 = req2.withContext(cancel_ctx);

                                var task = RoundTripTask{
                                    .transport = &transport,
                                    .req = &req2,
                                };
                                var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                                var joined = false;
                                defer if (!joined) thread.join();
                                try testing.expect(!task.waitTimeout(120));
                                cancel_ctx.cancel();
                                thread.join();
                                joined = true;

                                try testing.expect(task.err != null);
                                try testing.expectEqual(error.Canceled, task.err.?);
                            }
                        }.run,
                    );
                            
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
