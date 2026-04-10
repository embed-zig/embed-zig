//! Request — HTTP request model (in the style of Go's `http.Request`).
//!
//! This is the round-tripper-facing request shape used by `http.RoundTripper`.
//! It intentionally starts as a small client-oriented subset and can grow
//! as the parser/server/client layers land.

const std = @import("std");
const url_mod = @import("../url.zig");
const Context = @import("context").Context;
const ReadCloser = @import("ReadCloser.zig");
const Header = @import("Header.zig");
const testing_api = @import("testing");

const Request = @This();

pub const GetBody = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getBody: *const fn (ptr: *anyopaque) anyerror!ReadCloser,
    };

    pub fn getBody(self: GetBody) anyerror!ReadCloser {
        return self.vtable.getBody(self.ptr);
    }

    pub fn init(pointer: anytype) GetBody {
        const Ptr = @TypeOf(pointer);
        const info = @typeInfo(Ptr);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("GetBody.init expects a single-item pointer");

        const Impl = info.pointer.child;

        const gen = struct {
            fn getBodyFn(ptr: *anyopaque) anyerror!ReadCloser {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.getBody();
            }

            const vtable = VTable{
                .getBody = getBodyFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }
};

allocator: std.mem.Allocator,
method: []const u8 = "GET",
url: url_mod.Url,
proto: []const u8 = "HTTP/1.1",
proto_major: u8 = 1,
proto_minor: u8 = 1,
header: []const Header = &.{},
owned_header_storage: ?[]Header = null,
trailer: []const Header = &.{},
body_reader: ?ReadCloser = null,
get_body: ?GetBody = null,
content_length: i64 = 0,
transfer_encoding: []const []const u8 = &.{},
request_uri: []const u8 = "",
host: []const u8 = "",
close: bool = false,
ctx: ?Context = null,

pub fn init(allocator: std.mem.Allocator, method: []const u8, raw_url: []const u8) url_mod.ParseError!Request {
    return initParsed(allocator, method, try url_mod.parse(raw_url));
}

pub fn initParsed(allocator: std.mem.Allocator, method: []const u8, parsed_url: url_mod.Url) Request {
    return .{
        .allocator = allocator,
        .method = if (method.len == 0) "GET" else method,
        .url = parsed_url,
    };
}

pub fn deinit(self: *Request) void {
    if (self.owned_header_storage) |owned| {
        self.allocator.free(owned);
        self.owned_header_storage = null;
    }
    self.header = &.{};
}

pub fn effectiveMethod(self: Request) []const u8 {
    return if (self.method.len == 0) "GET" else self.method;
}

pub fn effectiveHost(self: Request) []const u8 {
    return if (self.host.len != 0) self.host else self.url.host;
}

pub fn hasBody(self: Request) bool {
    return self.body_reader != null or self.content_length > 0;
}

pub fn context(self: Request) ?Context {
    return self.ctx;
}

pub fn body(self: Request) ?ReadCloser {
    return self.body_reader;
}

pub fn withContext(self: Request, ctx: Context) Request {
    var req = self;
    req.ctx = ctx;
    return req;
}

pub fn withBody(self: Request, read_closer: ReadCloser) Request {
    var req = self;
    req.body_reader = read_closer;
    return req;
}

pub fn withGetBody(self: Request, get_body: GetBody) Request {
    var req = self;
    req.get_body = get_body;
    return req;
}

pub fn withTrailers(self: Request, trailers: []const Header) Request {
    var req = self;
    req.trailer = trailers;
    return req;
}

pub fn addHeader(self: *Request, name: []const u8, value: []const u8) std.mem.Allocator.Error!void {
    const extra = [_]Header{Header.init(name, value)};
    try self.addHeaders(&extra);
}

pub fn addHeaders(self: *Request, headers: []const Header) std.mem.Allocator.Error!void {
    if (headers.len == 0) return;

    const old_owned = self.owned_header_storage;
    const new_headers = try self.allocator.alloc(Header, self.header.len + headers.len);
    errdefer self.allocator.free(new_headers);

    @memcpy(new_headers[0..self.header.len], self.header);
    @memcpy(new_headers[self.header.len..], headers);

    self.header = new_headers;
    self.owned_header_storage = new_headers;
    if (old_owned) |owned| self.allocator.free(owned);
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            {
                const req = try Request.init(allocator, "", "https://example.com/api?q=1");
                try testing.expectEqualStrings("GET", req.effectiveMethod());
                try testing.expectEqualStrings("https", req.url.scheme);
                try testing.expectEqualStrings("example.com", req.url.host);
                try testing.expectEqualStrings("/api", req.url.path);
                try testing.expectEqualStrings("q=1", req.url.raw_query);
                try testing.expectEqualStrings("HTTP/1.1", req.proto);
                try testing.expectEqual(@as(u8, 1), req.proto_major);
                try testing.expectEqual(@as(u8, 1), req.proto_minor);
                try testing.expectEqual(@as(usize, 0), req.transfer_encoding.len);
                try testing.expectEqual(@as(usize, 0), req.trailer.len);
                try testing.expect(req.get_body == null);
                try testing.expectEqualStrings("", req.request_uri);
                try testing.expect(req.body() == null);
                try testing.expect(req.context() == null);
            }

            {
                var req = try Request.init(allocator, "POST", "https://example.com/upload");
                req.host = "api.example.com";
                try testing.expectEqualStrings("api.example.com", req.effectiveHost());
            }

            {
                const req = try Request.init(allocator, "GET", "https://example.com");
                const ContextApi = @import("context").make(lib);
                var context_api = try ContextApi.init(allocator);
                defer context_api.deinit();
                var deadline_ctx = try context_api.withDeadline(
                    context_api.background(),
                    5000,
                );
                defer deadline_ctx.deinit();

                const req_with_ctx = req.withContext(deadline_ctx);
                try testing.expect(req.context() == null);
                try testing.expect(req_with_ctx.context() != null);
                try testing.expectEqual(@as(?i128, 5000), req_with_ctx.context().?.deadline());
            }

            {
                const trailers = [_]Header{
                    Header.init("X-Trace", "1"),
                };

                const req = try Request.init(allocator, "POST", "http://example.com/upload");
                const req_with_trailers = req.withTrailers(&trailers);

                try testing.expectEqual(@as(usize, 0), req.trailer.len);
                try testing.expectEqual(@as(usize, 1), req_with_trailers.trailer.len);
                try testing.expectEqualStrings("X-Trace", req_with_trailers.trailer[0].name);
            }

            {
                var req = try Request.init(allocator, "GET", "https://example.com");
                defer req.deinit();

                try req.addHeader(Header.accept, "application/dns-message");
                try testing.expectEqual(@as(usize, 1), req.header.len);
                try testing.expectEqualStrings(Header.accept, req.header[0].name);
                try testing.expectEqualStrings("application/dns-message", req.header[0].value);
            }

            {
                var req = try Request.init(allocator, "POST", "https://example.com");
                defer req.deinit();

                try req.addHeader("X-First", "1");
                try req.addHeaders(&.{
                    Header.init("X-Second", "2"),
                    Header.init("X-Third", "3"),
                });

                try testing.expectEqual(@as(usize, 3), req.header.len);
                try testing.expectEqualStrings("X-First", req.header[0].name);
                try testing.expectEqualStrings("X-Second", req.header[1].name);
                try testing.expectEqualStrings("X-Third", req.header[2].name);
            }

            {
                const Factory = struct {
                    allocator: lib.mem.Allocator,
                    payload: []const u8,

                    const Body = struct {
                        allocator: lib.mem.Allocator,
                        payload: []const u8,
                        offset: usize = 0,

                        pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                            const remaining = self.payload[self.offset..];
                            const n = @min(buf.len, remaining.len);
                            @memcpy(buf[0..n], remaining[0..n]);
                            self.offset += n;
                            return n;
                        }

                        pub fn close(self: *@This()) void {
                            self.allocator.destroy(self);
                        }
                    };

                    pub fn getBody(self: *@This()) anyerror!ReadCloser {
                        const fresh_body = try self.allocator.create(Body);
                        fresh_body.* = .{
                            .allocator = self.allocator,
                            .payload = self.payload,
                        };
                        return ReadCloser.init(fresh_body);
                    }
                };

                var factory = Factory{
                    .allocator = allocator,
                    .payload = "abc",
                };
                const req = try Request.init(allocator, "POST", "http://example.com/upload");
                const req_with_get_body = req.withGetBody(GetBody.init(&factory));

                try testing.expect(req.get_body == null);
                try testing.expect(req_with_get_body.get_body != null);
                var reader = try req_with_get_body.get_body.?.getBody();
                defer reader.close();
                var buf: [4]u8 = undefined;
                try testing.expectEqual(@as(usize, 3), try reader.read(buf[0..3]));
                try testing.expectEqualStrings("abc", buf[0..3]);
            }
        }
    }.run);
}
