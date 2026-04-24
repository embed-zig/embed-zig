const io = @import("io");
const testing_api = @import("testing");
const http_harness = @import("test_utils/http_harness.zig");
const raw_http = @import("test_utils/raw_http.zig");

fn parseStreamWriteResult(comptime lib: type, body: []const u8) !struct { bytes: usize, reads: usize } {
    if (!lib.mem.startsWith(u8, body, "bytes=")) return error.BadResponse;
    const split = lib.mem.indexOf(u8, body, " reads=") orelse return error.BadResponse;
    const total_bytes = try lib.fmt.parseInt(usize, body[6..split], 10);
    const read_calls = try lib.fmt.parseInt(usize, body[split + 7 ..], 10);
    return .{
        .bytes = total_bytes,
        .reads = read_calls,
    };
}

// This case proves request-streaming and response-streaming over CMUX channels.
// It intentionally uses separate DLCIs instead of claiming one-request duplex HTTP semantics.
fn bidirectionalStreaming(comptime lib: type, comptime net: type, alloc: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const thread = lib.Thread;

    const Body = struct {
        fn run(cmux: *net.Cmux, a: lib.mem.Allocator) !void {
            {
                var conn = try http_harness.dialHttpChannel(lib, net, cmux, 50);
                defer conn.deinit();

                var content_length_buf: [16]u8 = undefined;
                const content_length = lib.fmt.bufPrint(
                    &content_length_buf,
                    "{d}",
                    .{http_harness.stream_write_total_bytes},
                ) catch return error.OutOfMemory;
                const headers = [_]raw_http.RequestHeader{
                    .{ .name = "Content-Length", .value = content_length },
                };

                try raw_http.writeRawRequest(lib, a, &conn, .{
                    .method = "POST",
                    .target = "/stream/write",
                    .headers = &headers,
                });

                var chunk: [http_harness.stream_write_chunk_bytes]u8 = undefined;
                for (0..http_harness.stream_write_total_bytes / http_harness.stream_write_chunk_bytes) |i| {
                    @memset(chunk[0..], @as(u8, @intCast('0' + i)));
                    try io.writeAll(net.Conn, &conn, chunk[0..]);
                    thread.sleep(5 * lib.time.ns_per_ms);
                }

                const resp = try raw_http.readRawResponse(lib, net, a, conn);
                defer a.free(resp.head);
                defer a.free(resp.body);

                try testing.expectEqual(@as(u16, 200), try raw_http.responseStatusCode(lib, resp.head));
                const stream_write = try parseStreamWriteResult(lib, resp.body);
                try testing.expectEqual(http_harness.stream_write_total_bytes, stream_write.bytes);
                try testing.expect(stream_write.reads >= 2);
            }

            {
                var conn = try http_harness.dialHttpChannel(lib, net, cmux, 51);
                defer conn.deinit();

                try raw_http.writeRawRequest(lib, a, &conn, .{
                    .target = "/stream/read",
                });

                const resp = try raw_http.readRawResponse(lib, net, a, conn);
                defer a.free(resp.head);
                defer a.free(resp.body);

                try testing.expectEqual(@as(u16, 200), try raw_http.responseStatusCode(lib, resp.head));
                try testing.expectEqual(http_harness.stream_read_total_bytes, resp.body.len);
                for (resp.body) |byte| try testing.expectEqual(@as(u8, 'r'), byte);
            }
        }
    };

    try http_harness.withCmuxHttpServer(lib, net, alloc, Body.run);
}

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            try bidirectionalStreaming(lib, net, allocator);
        }
    }.run);
}
