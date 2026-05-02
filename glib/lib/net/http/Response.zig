//! Response — HTTP response model (in the style of Go's `http.Response`).
//!
//! The response body is exposed as a `ReadCloser`, matching Go's streaming
//! response model.
//! The originating request is embedded by value so the response can
//! safely outlive the caller's local request variable.

const Header = @import("Header.zig");
const Request = @import("Request.zig");
const ReadCloser = @import("ReadCloser.zig");
const status_mod = @import("status.zig");
const testing_api = @import("testing");

const Response = @This();

pub const TlsConnectionState = struct {
    version: u16,
    cipher_suite: u16,
    peer_certificate_der: ?[]const u8 = null,
};

deinit_ptr: ?*anyopaque = null,
deinit_fn: ?*const fn (ptr: *anyopaque) void = null,
status: []const u8 = "",
status_code: u16,
proto: []const u8 = "HTTP/1.1",
proto_major: u8 = 1,
proto_minor: u8 = 1,
header: []const Header = &.{},
body_reader: ?ReadCloser = null,
content_length: i64 = -1,
close: bool = false,
request: ?Request = null,
tls: ?TlsConnectionState = null,

pub fn body(self: Response) ?ReadCloser {
    return self.body_reader;
}

pub fn ok(self: Response) bool {
    return status_mod.isSuccess(self.status_code);
}

pub fn deinit(self: *Response) void {
    if (self.body_reader) |read_closer| read_closer.close();
    if (self.deinit_fn) |f| {
        f(self.deinit_ptr orelse unreachable);
    }
    self.* = undefined;
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, _: std.mem.Allocator) !void {
            const testing = std.testing;

            const MockBody = struct {
                payload: []const u8 = "hello",
                offset: usize = 0,

                pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                    const remaining = self.payload[self.offset..];
                    const n = @min(buf.len, remaining.len);
                    @memcpy(buf[0..n], remaining[0..n]);
                    self.offset += n;
                    return n;
                }

                pub fn close(_: *@This()) void {}
            };

            var mock_body = MockBody{};
            const resp: Response = .{
                .status_code = 200,
                .body_reader = ReadCloser.init(&mock_body),
            };

            var buf: [8]u8 = undefined;
            const reader = resp.body().?;
            const n = try reader.read(&buf);

            try testing.expectEqualStrings("hello", buf[0..n]);
            try testing.expect(resp.ok());
            try testing.expect(resp.tls == null);

            var cleaned = false;
            const gen = struct {
                fn cleanup(ptr: *anyopaque) void {
                    const flag: *bool = @ptrCast(@alignCast(ptr));
                    flag.* = true;
                }
            };

            var cleanup_resp: Response = .{
                .status_code = 204,
                .deinit_ptr = @ptrCast(&cleaned),
                .deinit_fn = gen.cleanup,
            };

            cleanup_resp.deinit();
            try testing.expect(cleaned);

            const plain_resp: Response = .{
                .status_code = 200,
            };
            try testing.expect(plain_resp.tls == null);
        }
    }.run);
}
