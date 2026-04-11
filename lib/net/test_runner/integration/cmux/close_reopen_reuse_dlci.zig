const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const http_harness = @import("test_utils/http_harness.zig");
const raw_http = @import("test_utils/raw_http.zig");

fn expectPing(comptime lib: type, alloc: lib.mem.Allocator, conn: *net_mod.Conn) !void {
    const testing = lib.testing;

    try raw_http.writeRawRequest(lib, alloc, conn, .{
        .target = "/ping",
    });

    const resp = try raw_http.readRawResponse(lib, alloc, conn.*);
    defer alloc.free(resp.head);
    defer alloc.free(resp.body);

    try testing.expectEqual(@as(u16, 200), try raw_http.responseStatusCode(lib, resp.head));
    try testing.expectEqualStrings("pong", resp.body);
}

fn closeReopenReuseDlci(comptime lib: type, alloc: lib.mem.Allocator) !void {
    const Body = struct {
        fn run(cmux: *net_mod.make(lib).Cmux, a: lib.mem.Allocator) !void {
            for (0..3) |_| {
                var conn = try http_harness.dialHttpChannel(lib, cmux, 7);
                errdefer conn.deinit();
                try expectPing(lib, a, &conn);
                conn.close();
                try raw_http.expectConnClosed(lib, conn);
                conn.deinit();
            }
        }
    };

    try http_harness.withCmuxHttpServer(lib, alloc, Body.run);
}

pub fn make(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            try closeReopenReuseDlci(lib, allocator);
        }
    }.run);
}
