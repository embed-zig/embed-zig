const embed = @import("embed");
const context_mod = @import("context");
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
                    try Utils.withServerState(testing.allocator, 
                        WaitState{},
                        struct {
                            fn run(conn: net_mod.Conn, state: *WaitState) !void {
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "POST /upload-deadline HTTP/1.1"));
                                try state.wait(2000);
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, state: *WaitState) !void {
                                const Context = context_mod.make(lib);
                                var ctx_api = try Context.init(testing.allocator);
                                defer ctx_api.deinit();
                                var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 30 * lib.time.ns_per_ms);
                                defer ctx.deinit();

                                var transport = try Http.Transport.init(testing.allocator, .{});
                                var transport_active = true;
                                defer if (transport_active) transport.deinit();
                                defer state.signal();

                                const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/upload-deadline", .{port});
                                defer testing.allocator.free(url);

                                const payload_len = 32 * 1024 * 1024;
                                var source = RepeatingBodySource{
                                    .remaining = payload_len,
                                    .byte = 'd',
                                };

                                var req = try Http.Request.init(testing.allocator, "POST", url);
                                req = req.withContext(ctx).withBody(Http.ReadCloser.init(&source));
                                req.content_length = payload_len;
                                try testing.expectError(error.DeadlineExceeded, transport.roundTrip(&req));
                                transport.deinit();
                                transport_active = false;
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
