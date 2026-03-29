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

test "net/unit_tests/http/Request/init_parses_url_and_defaults_empty_method_to_GET" {
    const req = try Request.init(std.testing.allocator, "", "https://example.com/api?q=1");
    try std.testing.expectEqualStrings("GET", req.effectiveMethod());
    try std.testing.expectEqualStrings("https", req.url.scheme);
    try std.testing.expectEqualStrings("example.com", req.url.host);
    try std.testing.expectEqualStrings("/api", req.url.path);
    try std.testing.expectEqualStrings("q=1", req.url.raw_query);
    try std.testing.expectEqualStrings("HTTP/1.1", req.proto);
    try std.testing.expectEqual(@as(u8, 1), req.proto_major);
    try std.testing.expectEqual(@as(u8, 1), req.proto_minor);
    try std.testing.expectEqual(@as(usize, 0), req.transfer_encoding.len);
    try std.testing.expectEqual(@as(usize, 0), req.trailer.len);
    try std.testing.expect(req.get_body == null);
    try std.testing.expectEqualStrings("", req.request_uri);
    try std.testing.expect(req.body() == null);
    try std.testing.expect(req.context() == null);
}

test "net/unit_tests/http/Request/effectiveHost_prefers_explicit_Host_override" {
    var req = try Request.init(std.testing.allocator, "POST", "https://example.com/upload");
    req.host = "api.example.com";

    try std.testing.expectEqualStrings("api.example.com", req.effectiveHost());
}

test "net/unit_tests/http/Request/withContext_replaces_request_context" {
    const req = try Request.init(std.testing.allocator, "GET", "https://example.com");

    const gen = struct {
        const FakeRoot = struct {
            allocator: std.mem.Allocator = std.testing.allocator,
            tree: Context.TreeLink = .{},
            tree_rw: std.Thread.RwLock = .{},
        };

        fn errFn(_: *anyopaque) ?anyerror {
            return null;
        }
        fn deadlineFn(_: *anyopaque) ?i128 {
            return 5000;
        }
        fn valueFn(_: *anyopaque, _: *const anyopaque) ?*const anyopaque {
            return null;
        }
        fn waitFn(_: *anyopaque, _: ?i64) ?anyerror {
            return null;
        }
        fn cancelFn(_: *anyopaque) void {}
        fn cancelWithCauseFn(_: *anyopaque, _: anyerror) void {}
        fn propagateCancelWithCauseFn(_: *anyopaque, _: anyerror) void {}
        fn deinitFn(_: *anyopaque) void {}
        fn treeFn(ptr: *anyopaque) *Context.TreeLink {
            const self: *FakeRoot = @ptrCast(@alignCast(ptr));
            return &self.tree;
        }
        fn treeLockFn(ptr: *anyopaque) *anyopaque {
            const self: *FakeRoot = @ptrCast(@alignCast(ptr));
            return @ptrCast(&self.tree_rw);
        }
        fn reparentFn(_: *anyopaque, _: ?Context) void {}
        fn lockSharedFn(ptr: *anyopaque) void {
            const self: *FakeRoot = @ptrCast(@alignCast(ptr));
            self.tree_rw.lockShared();
        }
        fn unlockSharedFn(ptr: *anyopaque) void {
            const self: *FakeRoot = @ptrCast(@alignCast(ptr));
            self.tree_rw.unlockShared();
        }
        fn lockFn(ptr: *anyopaque) void {
            const self: *FakeRoot = @ptrCast(@alignCast(ptr));
            self.tree_rw.lock();
        }
        fn unlockFn(ptr: *anyopaque) void {
            const self: *FakeRoot = @ptrCast(@alignCast(ptr));
            self.tree_rw.unlock();
        }
    };

    const fake_vtable: Context.VTable = .{
        .errFn = gen.errFn,
        .deadlineFn = gen.deadlineFn,
        .valueFn = gen.valueFn,
        .waitFn = gen.waitFn,
        .cancelFn = gen.cancelFn,
        .cancelWithCauseFn = gen.cancelWithCauseFn,
        .propagateCancelWithCauseFn = gen.propagateCancelWithCauseFn,
        .deinitFn = gen.deinitFn,
        .treeFn = gen.treeFn,
        .treeLockFn = gen.treeLockFn,
        .reparentFn = gen.reparentFn,
        .lockSharedFn = gen.lockSharedFn,
        .unlockSharedFn = gen.unlockSharedFn,
        .lockFn = gen.lockFn,
        .unlockFn = gen.unlockFn,
    };
    var sentinel: gen.FakeRoot = .{};
    const fake_ctx = Context.init(&sentinel, &fake_vtable, std.testing.allocator);

    const req_with_ctx = req.withContext(fake_ctx);

    try std.testing.expect(req.context() == null);
    try std.testing.expect(req_with_ctx.context() != null);
    try std.testing.expectEqual(@as(?i128, 5000), req_with_ctx.context().?.deadline());
}

test "net/unit_tests/http/Request/withTrailers_replaces_request_trailers" {
    const trailers = [_]Header{
        Header.init("X-Trace", "1"),
    };

    const req = try Request.init(std.testing.allocator, "POST", "http://example.com/upload");
    const req_with_trailers = req.withTrailers(&trailers);

    try std.testing.expectEqual(@as(usize, 0), req.trailer.len);
    try std.testing.expectEqual(@as(usize, 1), req_with_trailers.trailer.len);
    try std.testing.expectEqualStrings("X-Trace", req_with_trailers.trailer[0].name);
}

test "net/unit_tests/http/Request/addHeader_appends_a_single_header" {
    var req = try Request.init(std.testing.allocator, "GET", "https://example.com");
    defer req.deinit();

    try req.addHeader(Header.accept, "application/dns-message");

    try std.testing.expectEqual(@as(usize, 1), req.header.len);
    try std.testing.expectEqualStrings(Header.accept, req.header[0].name);
    try std.testing.expectEqualStrings("application/dns-message", req.header[0].value);
}

test "net/unit_tests/http/Request/addHeaders_preserves_existing_headers" {
    var req = try Request.init(std.testing.allocator, "POST", "https://example.com");
    defer req.deinit();

    try req.addHeader("X-First", "1");
    try req.addHeaders(&.{
        Header.init("X-Second", "2"),
        Header.init("X-Third", "3"),
    });

    try std.testing.expectEqual(@as(usize, 3), req.header.len);
    try std.testing.expectEqualStrings("X-First", req.header[0].name);
    try std.testing.expectEqualStrings("X-Second", req.header[1].name);
    try std.testing.expectEqualStrings("X-Third", req.header[2].name);
}

test "net/unit_tests/http/Request/withGetBody_stores_request_body_factory" {
    const Factory = struct {
        payload: []const u8,

        const Body = struct {
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
                std.testing.allocator.destroy(self);
            }
        };

        pub fn getBody(self: *@This()) anyerror!ReadCloser {
            const fresh_body = try std.testing.allocator.create(Body);
            fresh_body.* = .{ .payload = self.payload };
            return ReadCloser.init(fresh_body);
        }
    };

    var factory = Factory{ .payload = "abc" };
    const req = try Request.init(std.testing.allocator, "POST", "http://example.com/upload");
    const req_with_get_body = req.withGetBody(GetBody.init(&factory));

    try std.testing.expect(req.get_body == null);
    try std.testing.expect(req_with_get_body.get_body != null);
    var reader = try req_with_get_body.get_body.?.getBody();
    defer reader.close();
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try reader.read(buf[0..3]));
    try std.testing.expectEqualStrings("abc", buf[0..3]);
}
