const testing_api = @import("testing");
const http_harness = @import("test_utils/http_harness.zig");
const raw_http = @import("test_utils/raw_http.zig");

fn expectPing(comptime lib: type, comptime net: type, alloc: lib.mem.Allocator, conn: *net.Conn) !void {
    const testing = lib.testing;

    try raw_http.writeRawRequest(lib, alloc, conn, .{
        .target = "/ping",
    });

    const resp = try raw_http.readRawResponse(lib, net, alloc, conn.*);
    defer alloc.free(resp.head);
    defer alloc.free(resp.body);

    try testing.expectEqual(@as(u16, 200), try raw_http.responseStatusCode(lib, resp.head));
    try testing.expectEqualStrings("pong", resp.body);
}

fn closeReopenDifferentDlci(comptime lib: type, comptime net: type, alloc: lib.mem.Allocator) !void {
    const Body = struct {
        fn run(cmux: *net.Cmux, a: lib.mem.Allocator) !void {
            {
                var conn = try http_harness.dialHttpChannel(lib, net, cmux, 6);
                defer conn.deinit();
                try expectPing(lib, net, a, &conn);
                conn.close();
                try raw_http.expectConnClosed(lib, conn);
            }

            {
                var conn = try http_harness.dialHttpChannel(lib, net, cmux, 9);
                defer conn.deinit();
                try expectPing(lib, net, a, &conn);
                conn.close();
                try raw_http.expectConnClosed(lib, conn);
            }
        }
    };

    try http_harness.withCmuxHttpServer(lib, net, alloc, Body.run);
}

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            try closeReopenDifferentDlci(lib, net, allocator);
        }
    }.run);
}
