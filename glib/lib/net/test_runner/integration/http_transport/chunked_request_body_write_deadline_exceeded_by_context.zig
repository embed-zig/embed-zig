const stdz = @import("stdz");
const context_mod = @import("context");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Utils = test_utils.make2(lib, net);

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

                        fn wait(self: *@This(), timeout_ms: u32) !void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            if (self.client_done) return;
                            self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * lib.time.ns_per_ms) catch return error.TestUnexpectedResult;
                            if (!self.client_done) return error.TestUnexpectedResult;
                        }
                    };

                    const ChunkedBodySource = struct {
                        chunks: []const []const u8,
                        index: usize = 0,

                        pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                            if (self.index >= self.chunks.len) return 0;
                            const chunk = self.chunks[self.index];
                            self.index += 1;
                            @memcpy(buf[0..chunk.len], chunk);
                            return chunk.len;
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

                        fn waitTimeout(self: *@This(), timeout_ms: u32) bool {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            if (self.finished) return true;
                            self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * lib.time.ns_per_ms) catch {};
                            return self.finished;
                        }
                    };
                    try Utils.withServerState(testing.allocator, 
                        WaitState{},
                        struct {
                            fn run(conn: net.Conn, state: *WaitState) !void {
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "POST /upload-chunked-deadline HTTP/1.1"));
                                try testing.expectEqualStrings("chunked", Utils.headerValue(req_head, Http.Header.transfer_encoding) orelse "");
                                try testing.expectEqualStrings("100-continue", Utils.headerValue(req_head, Http.Header.expect) orelse "");
                                const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                                try testing.expectEqual(@as(usize, 0), req_head[head_end + 4 ..].len);
                                try state.wait(2000);
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, state: *WaitState) !void {
                                const Context = context_mod.make(lib);
                                var ctx_api = try Context.init(testing.allocator);
                                defer ctx_api.deinit();
                                var ctx = try ctx_api.withCancel(ctx_api.background());
                                defer ctx.deinit();

                                var transport = try Http.Transport.init(testing.allocator, .{});
                                var transport_active = true;
                                defer if (transport_active) transport.deinit();
                                defer state.signal();

                                const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/upload-chunked-deadline", .{port});
                                defer testing.allocator.free(url);

                                var source = ChunkedBodySource{ .chunks = &.{"deadline-me"} };

                                var req = try Http.Request.init(testing.allocator, "POST", url);
                                req = req.withContext(ctx).withBody(Http.ReadCloser.init(&source));
                                req.header = &.{Http.Header.init(Http.Header.expect, "100-continue")};

                                var task = RoundTripTask{
                                    .transport = &transport,
                                    .req = &req,
                                };
                                var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                                var joined = false;
                                defer if (!joined) thread.join();

                                const deadline_thread = try lib.Thread.spawn(.{}, struct {
                                    fn run(deadline_ctx: context_mod.Context, comptime thread_lib: type) void {
                                        thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                                        deadline_ctx.cancelWithCause(error.DeadlineExceeded);
                                    }
                                }.run, .{ ctx, lib });
                                defer deadline_thread.join();

                                thread.join();
                                joined = true;
                                transport.deinit();
                                transport_active = false;
                                try testing.expectEqual(error.DeadlineExceeded, task.err orelse return error.TestUnexpectedResult);
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
