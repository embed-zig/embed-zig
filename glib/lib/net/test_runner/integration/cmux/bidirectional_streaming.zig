const io = @import("io");
const testing_api = @import("testing");
const http_harness = @import("test_utils/http_harness.zig");
const raw_http = @import("test_utils/raw_http.zig");

fn parseStreamWriteResult(comptime std: type, body: []const u8) !struct { bytes: usize, reads: usize } {
    if (!std.mem.startsWith(u8, body, "bytes=")) return error.BadResponse;
    const split = std.mem.indexOf(u8, body, " reads=") orelse return error.BadResponse;
    const total_bytes = try std.fmt.parseInt(usize, body[6..split], 10);
    const read_calls = try std.fmt.parseInt(usize, body[split + 7 ..], 10);
    return .{
        .bytes = total_bytes,
        .reads = read_calls,
    };
}

// This case proves request-streaming and response-streaming over CMUX channels.
// It intentionally uses separate DLCIs instead of claiming one-request duplex HTTP semantics.
fn bidirectionalStreaming(comptime std: type, comptime net: type, alloc: std.mem.Allocator) !void {
    const testing = std.testing;
    const thread = std.Thread;

    const Body = struct {
        fn run(cmux: *net.Cmux, a: std.mem.Allocator) !void {
            {
                var conn = try http_harness.dialHttpChannel(std, net, cmux, 50);
                defer conn.deinit();

                var content_length_buf: [16]u8 = undefined;
                const content_length = std.fmt.bufPrint(
                    &content_length_buf,
                    "{d}",
                    .{http_harness.stream_write_total_bytes},
                ) catch return error.OutOfMemory;
                const headers = [_]raw_http.RequestHeader{
                    .{ .name = "Content-Length", .value = content_length },
                };

                try raw_http.writeRawRequest(std, a, &conn, .{
                    .method = "POST",
                    .target = "/stream/write",
                    .headers = &headers,
                });

                var chunk: [http_harness.stream_write_chunk_bytes]u8 = undefined;
                for (0..http_harness.stream_write_total_bytes / http_harness.stream_write_chunk_bytes) |i| {
                    @memset(chunk[0..], @as(u8, @intCast('0' + i)));
                    try io.writeAll(net.Conn, &conn, chunk[0..]);
                    thread.sleep(@intCast(5 * net.time.duration.MilliSecond));
                }

                const resp = try raw_http.readRawResponse(std, net, a, conn);
                defer a.free(resp.head);
                defer a.free(resp.body);

                try testing.expectEqual(@as(u16, 200), try raw_http.responseStatusCode(std, resp.head));
                const stream_write = try parseStreamWriteResult(std, resp.body);
                try testing.expectEqual(http_harness.stream_write_total_bytes, stream_write.bytes);
                try testing.expect(stream_write.reads >= 2);
            }

            {
                var conn = try http_harness.dialHttpChannel(std, net, cmux, 51);
                defer conn.deinit();

                try raw_http.writeRawRequest(std, a, &conn, .{
                    .target = "/stream/read",
                });

                const resp = try raw_http.readRawResponse(std, net, a, conn);
                defer a.free(resp.head);
                defer a.free(resp.body);

                try testing.expectEqual(@as(u16, 200), try raw_http.responseStatusCode(std, resp.head));
                try testing.expectEqual(http_harness.stream_read_total_bytes, resp.body.len);
                for (resp.body) |byte| try testing.expectEqual(@as(u8, 'r'), byte);
            }
        }
    };

    try http_harness.withCmuxHttpServer(std, net, alloc, Body.run);
}

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: std.mem.Allocator) !void {
            try bidirectionalStreaming(std, net, allocator);
        }
    }.run);
}
