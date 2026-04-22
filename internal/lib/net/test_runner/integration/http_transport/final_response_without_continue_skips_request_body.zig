const stdz = @import("stdz");
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

                    const Mutex = lib.Thread.Mutex;
                    const Condition = lib.Thread.Condition;

                    const BlockingBodySource = struct {
                        mutex: Mutex = .{},
                        cond: Condition = .{},
                        closed: bool = false,

                        pub fn read(self: *@This(), _: []u8) anyerror!usize {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            while (!self.closed) self.cond.wait(&self.mutex);
                            return 0;
                        }

                        pub fn close(self: *@This()) void {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            self.closed = true;
                            self.cond.broadcast();
                        }
                    };
                    const State = struct {
                        body: BlockingBodySource = .{},
                    };

                    try Utils.withServerState(testing.allocator, 
                        State{},
                        struct {
                            fn run(conn: net_mod.Conn, _: *State) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "POST /continue-skip HTTP/1.1"));
                                const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                                try testing.expectEqualStrings("100-continue", Utils.headerValue(req_head[0..head_end], Http.Header.expect) orelse "");
                                try testing.expectEqual(@as(usize, 0), req_head[head_end + 4 ..].len);

                                io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nskip") catch {};
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, state: *State) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{
                                    .expect_continue_timeout_ms = 200,
                                });
                                defer transport.deinit();

                                const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/continue-skip", .{port});
                                defer testing.allocator.free(url);

                                var req = try Http.Request.init(testing.allocator, "POST", url);
                                req = req.withBody(Http.ReadCloser.init(&state.body));
                                req.header = &.{Http.Header.init(Http.Header.expect, "100-continue")};
                                req.content_length = 5;

                                var resp = try transport.roundTrip(&req);
                                defer resp.deinit();

                                const body = try Utils.readBody(testing.allocator, resp);
                                defer testing.allocator.free(body);
                                try testing.expectEqualStrings("skip", body);
                                try testing.expect(state.body.closed);
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
