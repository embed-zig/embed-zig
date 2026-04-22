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

                    const EmptyState = struct {};

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
                    const payload = "hello after timeout";

                    try Utils.withServerState(testing.allocator, 
                        EmptyState{},
                        struct {
                            fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "POST /continue-timeout HTTP/1.1"));
                                const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                                try testing.expectEqualStrings("100-continue", Utils.headerValue(req_head[0..head_end], Http.Header.expect) orelse "");
                                try testing.expectEqual(@as(usize, 0), req_head[head_end + 4 ..].len);

                                c.setReadTimeout(400);
                                try testing.expect(Utils.requestBodyMatches(conn, req_head, payload));
                                c.setReadTimeout(null);
                                io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, _: *EmptyState) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{
                                    .expect_continue_timeout_ms = 10,
                                });
                                defer transport.deinit();

                                const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/continue-timeout", .{port});
                                defer testing.allocator.free(url);

                                var source = ChunkedBodySource{ .chunks = &.{payload} };
                                var req = try Http.Request.init(testing.allocator, "POST", url);
                                req = req.withBody(Http.ReadCloser.init(&source));
                                req.header = &.{Http.Header.init(Http.Header.expect, "100-continue")};
                                req.content_length = payload.len;

                                var resp = try transport.roundTrip(&req);
                                defer resp.deinit();

                                const body = try Utils.readBody(testing.allocator, resp);
                                defer testing.allocator.free(body);
                                try testing.expectEqualStrings("ok", body);
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
