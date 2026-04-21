const embed = @import("embed");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
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
                    const accept_count = try Utils.withTwoRequestKeepAliveServer(testing.allocator, .{
                        .first_request_line = "GET /max-conns-1 HTTP/1.1",
                        .second_request_line = "GET /max-conns-2 HTTP/1.1",
                        .first_body = "hello",
                        .second_body = "world",
                        .reuse_wait_timeout_ms = 150,
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{
                                .max_conns_per_host = 1,
                            });
                            defer transport.deinit();

                            const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-conns-1", .{port});
                            defer testing.allocator.free(url1);
                            const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-conns-2", .{port});
                            defer testing.allocator.free(url2);

                            var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                            var resp1 = try transport.roundTrip(&req1);

                            var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                            var task = RoundTripTask{
                                .transport = &transport,
                                .req = &req2,
                            };
                            var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                            var joined = false;
                            defer if (!joined) thread.join();

                            try testing.expect(!task.waitTimeout(120));
                            resp1.deinit();
                            thread.join();
                            joined = true;

                            if (task.err) |err| return err;
                            var resp2 = task.resp orelse return error.TestUnexpectedResult;
                            defer resp2.deinit();

                            const body2 = try Utils.readBody(testing.allocator, resp2);
                            defer testing.allocator.free(body2);
                            try testing.expectEqualStrings("world", body2);
                        }
                    }.run);

                    try testing.expectEqual(@as(usize, 2), accept_count);
                            
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
