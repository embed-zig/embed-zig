const stdz = @import("stdz");
const io = @import("io");
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

                    const Mutex = std.Thread.Mutex;
                    const Condition = std.Thread.Condition;

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
                    const State = struct {
                        body: PhasedBodySource = .{
                            .first = "hello",
                            .second = " world",
                        },
                    };

                    try Utils.withServerState(
                        testing.allocator,
                        State{},
                        struct {
                            fn run(conn: net.Conn, state: *State) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "POST /bodyless-early-response HTTP/1.1"));

                                const head_end = std.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                                var first: [5]u8 = undefined;
                                try Utils.readExpectedBytes(conn, req_head[head_end + 4 ..], &first);
                                try testing.expectEqualStrings(state.body.first, &first);

                                io.writeAll(@TypeOf(c), &c, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") catch {};
                            }
                        }.run,
                        struct {
                            fn run(_: std.mem.Allocator, port: u16, state: *State) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{});
                                defer transport.deinit();

                                const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/bodyless-early-response", .{port});
                                defer testing.allocator.free(url);

                                var req = try Http.Request.init(testing.allocator, "POST", url);
                                req = req.withBody(Http.ReadCloser.init(&state.body));
                                req.content_length = @intCast(state.body.first.len + state.body.second.len);

                                var resp = try transport.roundTrip(&req);
                                defer resp.deinit();

                                try testing.expectEqual(Http.status.no_content, resp.status_code);
                                try testing.expect(resp.body() == null);
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
