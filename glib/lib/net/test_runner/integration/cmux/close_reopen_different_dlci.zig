const testing_api = @import("testing");
const http_harness = @import("test_utils/http_harness.zig");
const raw_http = @import("test_utils/raw_http.zig");

fn expectPing(comptime std: type, comptime net: type, alloc: std.mem.Allocator, conn: *net.Conn) !void {
    const testing = std.testing;

    try raw_http.writeRawRequest(std, alloc, conn, .{
        .target = "/ping",
    });

    const resp = try raw_http.readRawResponse(std, net, alloc, conn.*);
    defer alloc.free(resp.head);
    defer alloc.free(resp.body);

    try testing.expectEqual(@as(u16, 200), try raw_http.responseStatusCode(std, resp.head));
    try testing.expectEqualStrings("pong", resp.body);
}

fn closeReopenDifferentDlci(comptime std: type, comptime net: type, alloc: std.mem.Allocator) !void {
    const Body = struct {
        fn run(cmux: *net.Cmux, a: std.mem.Allocator) !void {
            {
                var conn = try http_harness.dialHttpChannel(std, net, cmux, 6);
                defer conn.deinit();
                try expectPing(std, net, a, &conn);
                conn.close();
                try raw_http.expectConnClosed(std, net, conn);
            }

            {
                var conn = try http_harness.dialHttpChannel(std, net, cmux, 9);
                defer conn.deinit();
                try expectPing(std, net, a, &conn);
                conn.close();
                try raw_http.expectConnClosed(std, net, conn);
            }
        }
    };

    try http_harness.withCmuxHttpServer(std, net, alloc, Body.run);
}

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: std.mem.Allocator) !void {
            try closeReopenDifferentDlci(std, net, allocator);
        }
    }.run);
}
