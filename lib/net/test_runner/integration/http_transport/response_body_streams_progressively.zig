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
                    const State = struct {
                        client_read_first: Gate = .{},
                    };

                    try Utils.withServerState(testing.allocator, 
                        State{},
                        struct {
                            fn run(conn: net_mod.Conn, state: *State) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "GET /response-stream HTTP/1.1"));

                                io.writeAll(
                                    @TypeOf(c),
                                    &c,
                                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
                                        "5\r\nhello\r\n",
                                ) catch {};
                                state.client_read_first.wait();
                                io.writeAll(@TypeOf(c), &c, "6\r\n world\r\n0\r\n\r\n") catch {};
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, state: *State) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{});
                                defer transport.deinit();

                                const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/response-stream", .{port});
                                defer testing.allocator.free(url);

                                var req = try Http.Request.init(testing.allocator, "GET", url);
                                var resp = try transport.roundTrip(&req);
                                defer resp.deinit();

                                const body = resp.body() orelse return error.TestUnexpectedResult;
                                var first: [5]u8 = undefined;
                                try testing.expectEqual(@as(usize, 5), try body.read(&first));
                                try testing.expectEqualStrings("hello", &first);

                                state.client_read_first.signal();

                                var rest: [16]u8 = undefined;
                                const n = try body.read(&rest);
                                try testing.expectEqualStrings(" world", rest[0..n]);
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
