//! Response — HTTP response model (in the style of Go's `http.Response`).
//!
//! The response body is exposed as a `ReadCloser`, matching Go's streaming
//! response model.
//! The originating request is embedded by value so the response can
//! safely outlive the caller's local request variable.

const std = @import("std");
const Header = @import("Header.zig");
const Request = @import("Request.zig");
const ReadCloser = @import("ReadCloser.zig");
const status_mod = @import("status.zig");

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

test "net/unit_tests/http/Response/body_returns_response_read_closer" {
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

    try std.testing.expectEqualStrings("hello", buf[0..n]);
    try std.testing.expect(resp.ok());
    try std.testing.expect(resp.tls == null);
}

test "net/unit_tests/http/Response/deinit_calls_custom_cleanup_hook" {
    var cleaned = false;

    const gen = struct {
        fn cleanup(ptr: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = true;
        }
    };

    var resp: Response = .{
        .status_code = 204,
        .deinit_ptr = @ptrCast(&cleaned),
        .deinit_fn = gen.cleanup,
    };

    resp.deinit();
    try std.testing.expect(cleaned);
}

test "net/unit_tests/http/Response/tls_defaults_to_null" {
    const resp: Response = .{
        .status_code = 200,
    };

    try std.testing.expect(resp.tls == null);
}
