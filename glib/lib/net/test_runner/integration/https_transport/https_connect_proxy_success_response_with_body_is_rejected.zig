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
                    const testing = struct {
                        pub var allocator: std.mem.Allocator = undefined;
                        pub const expect = std.testing.expect;
                        pub const expectEqual = std.testing.expectEqual;
                        pub const expectEqualSlices = std.testing.expectEqualSlices;
                        pub const expectEqualStrings = std.testing.expectEqualStrings;
                        pub const expectError = std.testing.expectError;
                    };
                    testing.allocator = a;

                    var proxy_ln = try Net.listen(testing.allocator, .{ .address = Utils.addr4(0) });
                    defer proxy_ln.deinit();
                    const proxy_listener = try proxy_ln.as(Net.TcpListener);
                    const proxy_port = try Utils.tcpListenerPort(proxy_ln, Net);
                    var proxy_result = ThreadResult{};

                    var proxy_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.TcpListener, result: *ThreadResult) void {
                            var thread_err: ?anyerror = null;
                            defer result.finish(thread_err);

                            var conn = listener.accept() catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer conn.deinit();

                            var req_buf: [4096]u8 = undefined;
                            const req_head = Utils.readRequestHead(conn, &req_buf) catch |err| {
                                thread_err = err;
                                return;
                            };
                            if (!Utils.hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1")) {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            }

                            io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 Connection established\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnope") catch |err| {
                                thread_err = err;
                            };
                        }
                    }.run, .{ proxy_listener, &proxy_result });
                    defer proxy_thread.join();

                    const proxy_raw_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{proxy_port});
                    defer testing.allocator.free(proxy_raw_url);
                    var options = Utils.tlsTransportOptions();
                    options.https_proxy = .{
                        .url = try net.url.parse(proxy_raw_url),
                    };
                    var transport = try Http.Transport.init(testing.allocator, options);
                    defer transport.deinit();

                    var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/invalid-connect-success");
                    try testing.expectError(error.InvalidResponse, transport.roundTrip(&req));
                    if (proxy_result.wait()) |err| return err;
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
