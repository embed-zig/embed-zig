const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const http_harness = @import("test_utils/http_harness.zig");
const raw_http = @import("test_utils/raw_http.zig");

fn concurrentRequests(comptime lib: type, alloc: lib.mem.Allocator) !void {
    const net = net_mod.make(lib);
    const testing = lib.testing;
    const thread = lib.Thread;

    const worker_count = 8;
    const round_count = 2;

    const Body = struct {
        fn run(cmux: *net.Cmux, a: lib.mem.Allocator) !void {
            const Worker = struct {
                cmux: *net.Cmux,
                arena: lib.mem.Allocator,
                dlci: u16,
                round_idx: usize,
                worker_idx: usize,
                err: ?anyerror = null,

                fn exec(self: *@This()) void {
                    self.run() catch |err| {
                        self.err = err;
                    };
                }

                fn run(self: *@This()) !void {
                    var conn = try http_harness.dialHttpChannel(lib, self.cmux, self.dlci);
                    defer conn.deinit();

                    const target = try lib.fmt.allocPrint(
                        self.arena,
                        "/echo?id=r{d}w{d}",
                        .{ self.round_idx, self.worker_idx },
                    );
                    defer self.arena.free(target);

                    try raw_http.writeRawRequest(lib, self.arena, &conn, .{
                        .target = target,
                    });

                    const resp = try raw_http.readRawResponse(lib, self.arena, conn);
                    defer self.arena.free(resp.head);
                    defer self.arena.free(resp.body);

                    try testing.expectEqual(@as(u16, 200), try raw_http.responseStatusCode(lib, resp.head));

                    var expect_buf: [32]u8 = undefined;
                    const expect = lib.fmt.bufPrint(
                        &expect_buf,
                        "echo:r{d}w{d}",
                        .{ self.round_idx, self.worker_idx },
                    ) catch return error.OutOfMemory;
                    try testing.expectEqualStrings(expect, resp.body);
                }
            };

            var round_idx: usize = 0;
            while (round_idx < round_count) : (round_idx += 1) {
                var workers: [worker_count]Worker = undefined;
                var threads: [worker_count]thread = undefined;

                for (0..worker_count) |worker_idx| {
                    workers[worker_idx] = .{
                        .cmux = cmux,
                        .arena = a,
                        .dlci = @intCast(2 + worker_idx),
                        .round_idx = round_idx,
                        .worker_idx = worker_idx,
                    };
                    threads[worker_idx] = try thread.spawn(
                        .{ .stack_size = 256 * 1024 },
                        Worker.exec,
                        .{&workers[worker_idx]},
                    );
                }

                for (threads) |worker_thread| worker_thread.join();
                for (workers) |worker| if (worker.err) |err| return err;
            }
        }
    };

    try http_harness.withCmuxHttpServer(lib, alloc, Body.run);
}

pub fn make(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            try concurrentRequests(lib, allocator);
        }
    }.run);
}
