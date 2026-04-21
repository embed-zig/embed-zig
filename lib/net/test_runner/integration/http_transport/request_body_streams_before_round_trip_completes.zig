const embed = @import("embed");
const io = @import("io");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
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

                    const Gate = struct {
                        mutex: Mutex = .{},
                        cond: Condition = .{},
                        open: bool = false,

                        fn signal(self: *@This()) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            self.open = true;
                            self.cond.broadcast();
                        }

                        fn wait(self: *@This()) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            while (!self.open) self.cond.wait(&self.mutex);
                        }
                    };

                    const PhasedBodySource = struct {
                        first: []const u8,
                        second: []const u8,
                        mutex: Mutex = .{},
                        cond: Condition = .{},
                        first_sent: bool = false,
                        second_released: bool = false,
                        closed: bool = false,
                        stage: enum {
                            first,
                            wait_second,
                            second,
                            done,
                        } = .first,

                        pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                            self.mutex.lock();
                            defer self.mutex.unlock();

                            while (true) switch (self.stage) {
                                .first => {
                                    @memcpy(buf[0..self.first.len], self.first);
                                    self.first_sent = true;
                                    self.stage = .wait_second;
                                    self.cond.broadcast();
                                    return self.first.len;
                                },
                                .wait_second => {
                                    while (!self.second_released and !self.closed) self.cond.wait(&self.mutex);
                                    if (self.closed) {
                                        self.stage = .done;
                                        return 0;
                                    }
                                    self.stage = .second;
                                },
                                .second => {
                                    @memcpy(buf[0..self.second.len], self.second);
                                    self.stage = .done;
                                    return self.second.len;
                                },
                                .done => return 0,
                            };
                        }

                        pub fn close(self: *@This()) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            self.closed = true;
                            self.cond.broadcast();
                        }

                        fn waitUntilFirstSent(self: *@This()) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            while (!self.first_sent) self.cond.wait(&self.mutex);
                        }

                        fn releaseSecond(self: *@This()) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            self.second_released = true;
                            self.cond.broadcast();
                        }
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
                    const State = struct {
                        body: PhasedBodySource = .{
                            .first = "ping",
                            .second = "pong",
                        },
                        server_saw_first: Gate = .{},
                    };

                    try Utils.withServerState(testing.allocator, 
                        State{},
                        struct {
                            fn run(conn: net_mod.Conn, state: *State) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "POST /request-stream HTTP/1.1"));

                                const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                                var first: [4]u8 = undefined;
                                try Utils.readExpectedBytes(conn, req_head[head_end + 4 ..], &first);
                                try testing.expectEqualStrings(state.body.first, &first);
                                state.server_saw_first.signal();

                                var rest: [4]u8 = undefined;
                                try io.readFull(@TypeOf(c), &c, &rest);
                                try testing.expectEqualStrings(state.body.second, &rest);

                                io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nuploaded") catch {};
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, state: *State) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{});
                                defer transport.deinit();

                                const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/request-stream", .{port});
                                defer testing.allocator.free(url);

                                var req = try Http.Request.init(testing.allocator, "POST", url);
                                req = req.withBody(Http.ReadCloser.init(&state.body));
                                req.content_length = @intCast(state.body.first.len + state.body.second.len);

                                var task = RoundTripTask{
                                    .transport = &transport,
                                    .req = &req,
                                };
                                var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});

                                state.server_saw_first.wait();
                                state.body.releaseSecond();
                                thread.join();

                                if (task.err) |err| return err;
                                var resp = task.resp orelse return error.TestUnexpectedResult;
                                defer resp.deinit();

                                const body = try Utils.readBody(testing.allocator, resp);
                                defer testing.allocator.free(body);
                                try testing.expectEqualStrings("uploaded", body);
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
