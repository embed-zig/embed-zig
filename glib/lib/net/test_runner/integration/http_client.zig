//! HTTP client local runner — local HTTP client coverage.

const testing_api = @import("testing");
const test_utils = @import("http_transport/test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Utils = test_utils.make2(lib, net);

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, run_allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Http = Utils.Http;
                    const Mutex = lib.Thread.Mutex;
                    const Condition = lib.Thread.Condition;
                    const test_spawn_config: lib.Thread.SpawnConfig = .{};
                    const testing = struct {
                        pub var allocator: lib.mem.Allocator = undefined;
                        pub const expect = lib.testing.expect;
                        pub const expectEqual = lib.testing.expectEqual;
                        pub const expectEqualStrings = lib.testing.expectEqualStrings;
                        pub const expectError = lib.testing.expectError;
                    };
                    testing.allocator = a;

                    try Utils.withOneShotServer(testing.allocator, .{
                        .expected_request_line = "GET /client-ok HTTP/1.1",
                        .status_code = Http.status.ok,
                        .body = "ok",
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{});
                            defer transport.deinit();
                            var client = try Http.Client.init(testing.allocator, .{
                                .round_tripper = transport.roundTripper(),
                            });
                            defer client.deinit();

                            const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/client-ok", .{port});
                            defer testing.allocator.free(url);

                            var resp = try client.get(url);
                            defer resp.deinit();

                            const body = try Utils.readBody(testing.allocator, resp);
                            defer testing.allocator.free(body);

                            try testing.expectEqual(Http.status.ok, resp.status_code);
                            try testing.expectEqualStrings("ok", body);
                        }
                    }.run);

                    try Utils.withOneShotServer(testing.allocator, .{
                        .expected_request_line = "HEAD /client-head HTTP/1.1",
                        .status_code = Http.status.ok,
                        .body = "",
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{});
                            defer transport.deinit();
                            var client = try Http.Client.init(testing.allocator, .{
                                .round_tripper = transport.roundTripper(),
                            });
                            defer client.deinit();

                            const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/client-head", .{port});
                            defer testing.allocator.free(url);

                            var resp = try client.head(url);
                            defer resp.deinit();

                            try testing.expectEqual(Http.status.ok, resp.status_code);
                            try testing.expect(resp.body() == null);
                        }
                    }.run);

                    _ = try Utils.withRedirectServer(testing.allocator, .{
                        .first_request_line = "GET /client-start HTTP/1.1",
                        .second_request_line = "GET /client-target HTTP/1.1",
                        .location = "/client-target",
                        .final_body = "redirected",
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{});
                            defer transport.deinit();
                            var client = try Http.Client.init(testing.allocator, .{
                                .round_tripper = transport.roundTripper(),
                            });
                            defer client.deinit();

                            const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/client-start", .{port});
                            defer testing.allocator.free(url);

                            var resp = try client.get(url);
                            defer resp.deinit();

                            const body = try Utils.readBody(testing.allocator, resp);
                            defer testing.allocator.free(body);

                            try testing.expectEqual(Http.status.ok, resp.status_code);
                            try testing.expectEqualStrings("redirected", body);
                            try testing.expect(resp.request != null);
                            try testing.expectEqualStrings("/client-target", resp.request.?.url.path);
                        }
                    }.run);

                    const accept_count = try Utils.withTwoRequestKeepAliveServer(testing.allocator, .{
                        .first_request_line = "GET /client-idle HTTP/1.1",
                        .second_request_line = "GET /client-idle HTTP/1.1",
                        .first_body = "one",
                        .second_body = "two",
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{});
                            defer transport.deinit();
                            var client = try Http.Client.init(testing.allocator, .{
                                .round_tripper = transport.roundTripper(),
                            });
                            defer client.deinit();

                            const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/client-idle", .{port});
                            defer testing.allocator.free(url);

                            var resp1 = try client.get(url);
                            const body1 = try Utils.readBody(testing.allocator, resp1);
                            defer testing.allocator.free(body1);
                            try testing.expectEqualStrings("one", body1);
                            resp1.deinit();

                            client.closeIdleConnections();

                            var resp2 = try client.get(url);
                            defer resp2.deinit();

                            const body2 = try Utils.readBody(testing.allocator, resp2);
                            defer testing.allocator.free(body2);
                            try testing.expectEqualStrings("two", body2);
                        }
                    }.run);
                    try testing.expectEqual(@as(usize, 2), accept_count);

                    try Utils.withOneShotServer(testing.allocator, .{
                        .expected_request_line = "GET /client-deinit HTTP/1.1",
                        .status_code = Http.status.ok,
                        .body = "wait",
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            const State = struct {
                                mutex: Mutex = .{},
                                cond: Condition = .{},
                                started: bool = false,
                                finished: bool = false,
                            };

                            const DeinitTask = struct {
                                fn run(client: *Http.Client, state: *State) void {
                                    state.mutex.lock();
                                    state.started = true;
                                    state.cond.broadcast();
                                    state.mutex.unlock();

                                    client.deinit();

                                    state.mutex.lock();
                                    state.finished = true;
                                    state.cond.broadcast();
                                    state.mutex.unlock();
                                }
                            };

                            var transport = try Http.Transport.init(testing.allocator, .{});
                            defer transport.deinit();
                            var client = try Http.Client.init(testing.allocator, .{
                                .round_tripper = transport.roundTripper(),
                            });
                            const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/client-deinit", .{port});
                            defer testing.allocator.free(url);

                            var resp = try client.get(url);

                            var state = State{};
                            const thread = try lib.Thread.spawn(test_spawn_config, DeinitTask.run, .{ &client, &state });

                            state.mutex.lock();
                            while (!state.started) state.cond.wait(&state.mutex);
                            state.mutex.unlock();

                            lib.Thread.sleep(20 * lib.time.ns_per_ms);

                            state.mutex.lock();
                            const finished_early = state.finished;
                            state.mutex.unlock();
                            try testing.expect(!finished_early);

                            resp.deinit();
                            thread.join();

                            state.mutex.lock();
                            defer state.mutex.unlock();
                            try testing.expect(state.finished);
                        }
                    }.run);
                }
            };
            Body.call(run_allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
