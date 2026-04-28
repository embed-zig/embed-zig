const stdz = @import("stdz");
const context_mod = @import("context");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Utils = test_utils.make2(std, net);

    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, run_allocator: std.mem.Allocator) bool {
            _ = runner;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    const Http = Utils.Http;
                    const testing = struct {
                        pub var allocator: std.mem.Allocator = undefined;
                        pub const expect = std.testing.expect;
                        pub const expectEqual = std.testing.expectEqual;
                        pub const expectEqualStrings = std.testing.expectEqualStrings;
                        pub const expectError = std.testing.expectError;
                    };
                    testing.allocator = a;
                    const test_spawn_config: std.Thread.SpawnConfig = .{};

                    const Mutex = std.Thread.Mutex;
                    const Condition = std.Thread.Condition;

                    const WaitState = struct {
                        mutex: Mutex = .{},
                        cond: Condition = .{},
                        client_done: bool = false,

                        fn signal(self: *@This()) void {
                            self.mutex.lock();
                            self.client_done = true;
                            self.cond.broadcast();
                            self.mutex.unlock();
                        }

                        fn wait(self: *@This(), timeout: net.time.duration.Duration) !void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            if (self.client_done) return;
                            self.cond.timedWait(&self.mutex, @intCast(timeout)) catch return error.TestUnexpectedResult;
                            if (!self.client_done) return error.TestUnexpectedResult;
                        }
                    };

                    const RepeatingBodySource = struct {
                        remaining: usize,
                        byte: u8,

                        pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                            if (self.remaining == 0) return 0;
                            const n = @min(buf.len, self.remaining);
                            @memset(buf[0..n], self.byte);
                            self.remaining -= n;
                            return n;
                        }

                        pub fn close(_: *@This()) void {}
                    };

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

                        fn waitTimeout(self: *@This(), timeout: net.time.duration.Duration) bool {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            if (self.finished) return true;
                            self.cond.timedWait(&self.mutex, @intCast(timeout)) catch {};
                            return self.finished;
                        }
                    };
                    try Utils.withServerState(
                        testing.allocator,
                        WaitState{},
                        struct {
                            fn run(conn: net.Conn, state: *WaitState) !void {
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "POST /upload-cancel HTTP/1.1"));
                                try state.wait(2000 * net.time.duration.MilliSecond);
                            }
                        }.run,
                        struct {
                            fn run(_: std.mem.Allocator, port: u16, state: *WaitState) !void {
                                const Context = context_mod.make(std, net.time);
                                var ctx_api = try Context.init(testing.allocator);
                                defer ctx_api.deinit();
                                var ctx = try ctx_api.withCancel(ctx_api.background());
                                defer ctx.deinit();

                                var transport = try Http.Transport.init(testing.allocator, .{});
                                var transport_active = true;
                                defer if (transport_active) transport.deinit();
                                defer state.signal();

                                const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/upload-cancel", .{port});
                                defer testing.allocator.free(url);

                                const payload_len = 32 * 1024 * 1024;
                                var source = RepeatingBodySource{
                                    .remaining = payload_len,
                                    .byte = 'w',
                                };

                                var req = try Http.Request.init(testing.allocator, "POST", url);
                                req = req.withContext(ctx).withBody(Http.ReadCloser.init(&source));
                                req.content_length = payload_len;

                                var task = RoundTripTask{
                                    .transport = &transport,
                                    .req = &req,
                                };
                                var thread = try std.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                                var joined = false;
                                defer if (!joined) thread.join();
                                try testing.expect(!task.waitTimeout(120 * net.time.duration.MilliSecond));
                                ctx.cancel();
                                thread.join();
                                joined = true;
                                transport.deinit();
                                transport_active = false;
                                try testing.expectEqual(error.Canceled, task.err orelse return error.TestUnexpectedResult);
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
