//! Client — high-level HTTP client facade above `RoundTripper`.
//!
//! The first landed layer keeps the surface intentionally narrow:
//! allocator-explicit construction, owned-default-transport vs borrowed
//! round-tripper, request execution via `do`, and deterministic teardown.

const Header = @import("Header.zig");
const ReadCloser = @import("ReadCloser.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const RoundTripper = @import("RoundTripper.zig");
const status = @import("status.zig");
const transport_mod = @import("Transport.zig");
const url_mod = @import("../url.zig");

const RedirectAction = enum {
    none,
    rewrite_to_get,
    preserve_method,
};

pub fn Client(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Thread = lib.Thread;
    const Transport = transport_mod.Transport(lib);

    return struct {
        allocator: Allocator,
        options: Options,
        shared: *SharedState,
        transport_source: TransportSource,

        const Self = @This();

        pub const Options = struct {
            round_tripper: ?RoundTripper = null,
            transport: Transport.Options = .{},
            redirect_limit: usize = 10,
        };

        const SharedState = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            deiniting: bool = false,
            active_calls: usize = 0,
            active_requests: usize = 0,
        };

        const TransportSource = union(enum) {
            owned: *Transport,
            borrowed: RoundTripper,
        };

        const ResponseDeinitState = struct {
            allocator: Allocator,
            shared: *SharedState,
            upstream_ptr: ?*anyopaque = null,
            upstream_fn: ?*const fn (ptr: *anyopaque) void = null,
            extra_cleanup_ptr: ?*anyopaque = null,
            extra_cleanup_fn: ?*const fn (ptr: *anyopaque) void = null,
        };

        const OwnedRequestState = struct {
            allocator: Allocator,
            raw_url: []u8,
            request: Request,

            fn cleanup(ptr: *anyopaque) void {
                const self: *OwnedRequestState = @ptrCast(@alignCast(ptr));
                self.request.deinit();
                self.allocator.free(self.raw_url);
                self.allocator.destroy(self);
            }
        };

        pub fn init(allocator: Allocator, options: Options) Allocator.Error!Self {
            const shared = try allocator.create(SharedState);
            errdefer allocator.destroy(shared);
            shared.* = .{};

            var client: Self = .{
                .allocator = allocator,
                .options = options,
                .shared = shared,
                .transport_source = undefined,
            };

            if (options.round_tripper) |borrowed| {
                client.transport_source = .{ .borrowed = borrowed };
                return client;
            }

            const owned = try allocator.create(Transport);
            errdefer allocator.destroy(owned);
            owned.* = try Transport.init(allocator, options.transport);

            client.transport_source = .{ .owned = owned };
            return client;
        }

        pub fn deinit(self: *Self) void {
            self.shared.mutex.lock();
            self.shared.deiniting = true;
            while (self.shared.active_calls != 0 or self.shared.active_requests != 0) {
                self.shared.cond.wait(&self.shared.mutex);
            }
            self.shared.mutex.unlock();

            switch (self.transport_source) {
                .owned => |owned| {
                    owned.deinit();
                    self.allocator.destroy(owned);
                },
                .borrowed => {},
            }

            self.allocator.destroy(self.shared);
            self.* = undefined;
        }

        pub fn closeIdleConnections(self: *Self) void {
            switch (self.transport_source) {
                .owned => |owned| owned.closeIdleConnections(),
                .borrowed => {},
            }
        }

        pub fn do(self: *Self, req: *Request) RoundTripper.RoundTripError!Response {
            return self.execute(req, null);
        }

        pub fn get(self: *Self, raw_url: []const u8) RoundTripper.RoundTripError!Response {
            const request_state = try self.buildOwnedRequest("GET", raw_url);
            return self.execute(&request_state.request, request_state);
        }

        pub fn head(self: *Self, raw_url: []const u8) RoundTripper.RoundTripError!Response {
            const request_state = try self.buildOwnedRequest("HEAD", raw_url);
            return self.execute(&request_state.request, request_state);
        }

        fn execute(
            self: *Self,
            req: *Request,
            initial_cleanup: ?*OwnedRequestState,
        ) RoundTripper.RoundTripError!Response {
            try self.beginCall();
            defer self.finishCall();

            var current_req = req;
            var current_cleanup = initial_cleanup;
            errdefer if (current_cleanup) |cleanup| OwnedRequestState.cleanup(@ptrCast(cleanup));
            var followed_redirects: usize = 0;

            while (true) {
                var resp = try self.doRoundTrip(current_req, current_cleanup);
                current_cleanup = null;

                const action = redirectAction(lib, resp.status_code, current_req);
                const location = responseHeaderValue(resp.header, Header.location) orelse return resp;
                switch (action) {
                    .none => return resp,
                    else => {},
                }

                if (self.options.redirect_limit == 0) return resp;
                if (followed_redirects >= self.options.redirect_limit) {
                    resp.deinit();
                    return error.TooManyRedirects;
                }
                if (!canFollowRedirect(current_req, action)) return resp;

                const next_cleanup = self.buildRedirectRequest(current_req, location, action) catch |err| {
                    resp.deinit();
                    return err;
                };

                resp.deinit();
                current_req = &next_cleanup.request;
                current_cleanup = next_cleanup;
                followed_redirects += 1;
            }
        }

        fn currentRoundTripper(self: *Self) RoundTripper {
            return switch (self.transport_source) {
                .owned => |owned| owned.roundTripper(),
                .borrowed => |borrowed| borrowed,
            };
        }

        fn beginRequest(self: *Self) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            self.shared.active_requests += 1;
        }

        fn beginCall(self: *Self) error{Closed}!void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            if (self.shared.deiniting) return error.Closed;
            self.shared.active_calls += 1;
        }

        fn finishCall(self: *Self) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            lib.debug.assert(self.shared.active_calls > 0);
            self.shared.active_calls -= 1;
            if (self.shared.active_calls == 0 and self.shared.active_requests == 0) {
                self.shared.cond.broadcast();
            }
        }

        fn finishRequest(self: *Self) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            lib.debug.assert(self.shared.active_requests > 0);
            self.shared.active_requests -= 1;
            if (self.shared.active_requests == 0) self.shared.cond.broadcast();
        }

        fn attachResponseTracking(
            self: *Self,
            allocator: Allocator,
            resp: *Response,
            extra_cleanup_ptr: ?*anyopaque,
            extra_cleanup_fn: ?*const fn (ptr: *anyopaque) void,
        ) Allocator.Error!void {
            const state = try allocator.create(ResponseDeinitState);
            state.* = .{
                .allocator = allocator,
                .shared = self.shared,
                .upstream_ptr = resp.deinit_ptr,
                .upstream_fn = resp.deinit_fn,
                .extra_cleanup_ptr = extra_cleanup_ptr,
                .extra_cleanup_fn = extra_cleanup_fn,
            };

            resp.deinit_ptr = @ptrCast(state);
            resp.deinit_fn = trackedResponseDeinit;
        }

        fn trackedResponseDeinit(ptr: *anyopaque) void {
            const state: *ResponseDeinitState = @ptrCast(@alignCast(ptr));
            defer state.allocator.destroy(state);

            if (state.upstream_fn) |upstream_fn| {
                upstream_fn(state.upstream_ptr orelse unreachable);
            }
            if (state.extra_cleanup_fn) |extra_cleanup_fn| {
                extra_cleanup_fn(state.extra_cleanup_ptr orelse unreachable);
            }

            state.shared.mutex.lock();
            defer state.shared.mutex.unlock();

            lib.debug.assert(state.shared.active_requests > 0);
            state.shared.active_requests -= 1;
            if (state.shared.active_requests == 0) state.shared.cond.broadcast();
        }

        fn doRoundTrip(
            self: *Self,
            req: *Request,
            request_cleanup: ?*OwnedRequestState,
        ) RoundTripper.RoundTripError!Response {
            self.beginRequest();
            errdefer self.finishRequest();

            var resp = try self.currentRoundTripper().roundTrip(req);
            self.attachResponseTracking(
                req.allocator,
                &resp,
                if (request_cleanup) |cleanup| @ptrCast(cleanup) else null,
                if (request_cleanup != null) OwnedRequestState.cleanup else null,
            ) catch |err| {
                resp.deinit();
                return err;
            };
            return resp;
        }

        fn buildRedirectRequest(
            self: *Self,
            req: *Request,
            location: []const u8,
            action: RedirectAction,
        ) anyerror!*OwnedRequestState {
            const raw_url = try resolveRedirectUrl(lib, self.allocator, req.url, location);
            errdefer self.allocator.free(raw_url);

            const parsed = try url_mod.parse(raw_url);
            const state = try self.allocator.create(OwnedRequestState);
            errdefer self.allocator.destroy(state);

            var next = Request.initParsed(req.allocator, redirectMethod(lib, req, action), parsed);
            next.proto = req.proto;
            next.proto_major = req.proto_major;
            next.proto_minor = req.proto_minor;
            next.close = req.close;
            next.ctx = req.ctx;

            const filtered_headers = try filterRedirectHeaders(lib, req.allocator, req.header);
            next.header = filtered_headers;
            next.owned_header_storage = if (filtered_headers.len == 0) null else filtered_headers;
            errdefer next.deinit();

            switch (action) {
                .rewrite_to_get => {
                    next.body_reader = null;
                    next.get_body = null;
                    next.content_length = 0;
                    next.transfer_encoding = &.{};
                    next.trailer = &.{};
                },
                .preserve_method => {
                    next.content_length = req.content_length;
                    next.transfer_encoding = req.transfer_encoding;
                    next.trailer = req.trailer;
                    next.get_body = req.get_body;
                    if (req.body()) |_| {
                        const get_body = req.get_body orelse return error.CannotReplayRequest;
                        next.body_reader = try get_body.getBody();
                    }
                },
                .none => unreachable,
            }

            state.* = .{
                .allocator = self.allocator,
                .raw_url = raw_url,
                .request = next,
            };
            return state;
        }

        fn buildOwnedRequest(self: *Self, method: []const u8, raw_url: []const u8) anyerror!*OwnedRequestState {
            const owned_raw_url = try self.allocator.dupe(u8, raw_url);
            errdefer self.allocator.free(owned_raw_url);

            const parsed = try url_mod.parse(owned_raw_url);
            const state = try self.allocator.create(OwnedRequestState);
            errdefer self.allocator.destroy(state);

            state.* = .{
                .allocator = self.allocator,
                .raw_url = owned_raw_url,
                .request = Request.initParsed(self.allocator, method, parsed),
            };
            return state;
        }
    };
}

fn redirectAction(comptime lib: type, req_status: u16, req: *const Request) RedirectAction {
    return switch (req_status) {
        status.moved_permanently,
        status.found,
        => if (lib.ascii.eqlIgnoreCase(req.effectiveMethod(), "HEAD")) .preserve_method else .rewrite_to_get,
        status.see_other => .rewrite_to_get,
        status.temporary_redirect,
        status.permanent_redirect,
        => .preserve_method,
        else => .none,
    };
}

fn canFollowRedirect(req: *const Request, action: RedirectAction) bool {
    return switch (action) {
        .none => false,
        .rewrite_to_get => true,
        .preserve_method => req.body() == null or req.get_body != null,
    };
}

fn redirectMethod(comptime lib: type, req: *const Request, action: RedirectAction) []const u8 {
    return switch (action) {
        .rewrite_to_get => if (lib.ascii.eqlIgnoreCase(req.effectiveMethod(), "HEAD")) "HEAD" else "GET",
        .preserve_method => req.effectiveMethod(),
        .none => req.effectiveMethod(),
    };
}

fn responseHeaderValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |hdr| {
        if (hdr.is(name)) return hdr.value;
    }
    return null;
}

fn filterRedirectHeaders(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    headers: []const Header,
) lib.mem.Allocator.Error![]Header {
    var kept: usize = 0;
    for (headers) |hdr| {
        if (shouldKeepRedirectHeader(hdr)) kept += 1;
    }
    if (kept == 0) return &.{};

    const out = try allocator.alloc(Header, kept);
    var idx: usize = 0;
    for (headers) |hdr| {
        if (!shouldKeepRedirectHeader(hdr)) continue;
        out[idx] = hdr;
        idx += 1;
    }
    return out;
}

fn shouldKeepRedirectHeader(hdr: Header) bool {
    if (hdr.is(Header.host)) return false;
    if (hdr.is(Header.content_length)) return false;
    if (hdr.is(Header.transfer_encoding)) return false;
    if (hdr.is(Header.trailer)) return false;
    return true;
}

fn resolveRedirectUrl(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    base: url_mod.Url,
    location: []const u8,
) ![]u8 {
    const parts = splitReference(lib, location);

    if (hasUrlScheme(lib, location)) return allocator.dupe(u8, location);

    var out = lib.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.appendSlice(allocator, base.scheme);
    try out.appendSlice(allocator, "://");
    try appendAuthority(lib, &out, allocator, base);

    if (lib.mem.startsWith(u8, location, "//")) {
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, base.scheme);
        try out.appendSlice(allocator, ":");
        try out.appendSlice(allocator, location);
        return out.toOwnedSlice(allocator);
    }
    if (location.len == 0) {
        try appendPathQueryFragment(lib, &out, allocator, base.path, base.raw_query, base.fragment);
        return out.toOwnedSlice(allocator);
    }
    if (location[0] == '/') {
        const normalized = try normalizePath(lib, allocator, parts.path);
        defer allocator.free(normalized);
        try out.appendSlice(allocator, normalized);
        try appendQueryFragment(lib, &out, allocator, parts.query, parts.fragment);
        return out.toOwnedSlice(allocator);
    }
    if (location[0] == '?') {
        const path = if (base.path.len == 0) "/" else base.path;
        try out.appendSlice(allocator, path);
        try out.appendSlice(allocator, location);
        return out.toOwnedSlice(allocator);
    }
    if (location[0] == '#') {
        try appendPathQueryFragment(lib, &out, allocator, base.path, base.raw_query, "");
        try out.appendSlice(allocator, location);
        return out.toOwnedSlice(allocator);
    }

    const base_dir = baseDirectory(lib, base.path);
    var combined = lib.ArrayList(u8){};
    defer combined.deinit(allocator);
    try combined.appendSlice(allocator, base_dir);
    try combined.appendSlice(allocator, parts.path);
    const normalized = try normalizePath(lib, allocator, combined.items);
    defer allocator.free(normalized);
    try out.appendSlice(allocator, normalized);
    try appendQueryFragment(lib, &out, allocator, parts.query, parts.fragment);
    return out.toOwnedSlice(allocator);
}

fn hasUrlScheme(comptime lib: type, location: []const u8) bool {
    return lib.mem.indexOf(u8, location, "://") != null;
}

fn appendAuthority(
    comptime lib: type,
    out: *lib.ArrayList(u8),
    allocator: lib.mem.Allocator,
    base: url_mod.Url,
) !void {
    if (base.username.len != 0) {
        try out.appendSlice(allocator, base.username);
        if (base.password.len != 0) {
            try out.append(allocator, ':');
            try out.appendSlice(allocator, base.password);
        }
        try out.append(allocator, '@');
    }

    if (lib.mem.indexOfScalar(u8, base.host, ':') != null) {
        try out.append(allocator, '[');
        try out.appendSlice(allocator, base.host);
        try out.append(allocator, ']');
    } else {
        try out.appendSlice(allocator, base.host);
    }
    if (base.port.len != 0) {
        try out.append(allocator, ':');
        try out.appendSlice(allocator, base.port);
    }
}

fn appendPathQueryFragment(
    comptime lib: type,
    out: *lib.ArrayList(u8),
    allocator: lib.mem.Allocator,
    path: []const u8,
    raw_query: []const u8,
    fragment: []const u8,
) !void {
    if (path.len != 0) {
        try out.appendSlice(allocator, path);
    } else {
        try out.append(allocator, '/');
    }
    if (raw_query.len != 0) {
        try out.append(allocator, '?');
        try out.appendSlice(allocator, raw_query);
    }
    if (fragment.len != 0) {
        try out.append(allocator, '#');
        try out.appendSlice(allocator, fragment);
    }
}

fn appendQueryFragment(
    comptime lib: type,
    out: *lib.ArrayList(u8),
    allocator: lib.mem.Allocator,
    raw_query: []const u8,
    fragment: []const u8,
) !void {
    if (raw_query.len != 0) {
        try out.append(allocator, '?');
        try out.appendSlice(allocator, raw_query);
    }
    if (fragment.len != 0) {
        try out.append(allocator, '#');
        try out.appendSlice(allocator, fragment);
    }
}

fn baseDirectory(comptime lib: type, path: []const u8) []const u8 {
    if (path.len == 0) return "/";
    const slash = lib.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (slash == 0) "/" else path[0 .. slash + 1];
}

fn normalizePath(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    path: []const u8,
) lib.mem.Allocator.Error![]u8 {
    const absolute = path.len != 0 and path[0] == '/';
    const preserve_trailing_slash = path.len != 0 and path[path.len - 1] == '/';

    var segments = lib.ArrayList([]const u8){};
    defer segments.deinit(allocator);

    var i: usize = 0;
    while (i <= path.len) {
        const next_slash = lib.mem.indexOfScalarPos(u8, path, i, '/') orelse path.len;
        const segment = path[i..next_slash];
        if (segment.len != 0 and !lib.mem.eql(u8, segment, ".")) {
            if (lib.mem.eql(u8, segment, "..")) {
                if (segments.items.len != 0) _ = segments.pop();
            } else {
                try segments.append(allocator, segment);
            }
        }
        if (next_slash == path.len) break;
        i = next_slash + 1;
    }

    var out = lib.ArrayList(u8){};
    defer out.deinit(allocator);

    if (absolute) try out.append(allocator, '/');
    for (segments.items, 0..) |segment, idx| {
        if (idx != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }
    if (preserve_trailing_slash and (out.items.len == 0 or out.items[out.items.len - 1] != '/')) {
        try out.append(allocator, '/');
    }
    if (out.items.len == 0 and absolute) try out.append(allocator, '/');
    return out.toOwnedSlice(allocator);
}

const ReferenceParts = struct {
    path: []const u8,
    query: []const u8,
    fragment: []const u8,
};

fn splitReference(comptime lib: type, input: []const u8) ReferenceParts {
    var parts: ReferenceParts = .{
        .path = input,
        .query = "",
        .fragment = "",
    };

    if (lib.mem.indexOfScalar(u8, parts.path, '#')) |hash| {
        parts.fragment = parts.path[hash + 1 ..];
        parts.path = parts.path[0..hash];
    }
    if (lib.mem.indexOfScalar(u8, parts.path, '?')) |query| {
        parts.query = parts.path[query + 1 ..];
        parts.path = parts.path[0..query];
    }
    return parts;
}

test "net/unit_tests/http/Client/init_without_custom_roundtripper_owns_default_transport" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    var client = try HttpClient.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expect(client.transport_source == .owned);
    client.closeIdleConnections();
}

test "net/unit_tests/http/Client/do_with_borrowed_roundtripper_tracks_response_until_deinit" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const MockRoundTripper = struct {
        cleaned: bool = false,
        calls: usize = 0,

        pub fn roundTrip(self: *@This(), req: *const Request) anyerror!Response {
            _ = req;
            self.calls += 1;
            return .{
                .status_code = 200,
                .deinit_ptr = @ptrCast(&self.cleaned),
                .deinit_fn = cleanup,
            };
        }

        fn cleanup(ptr: *anyopaque) void {
            const cleaned: *bool = @ptrCast(@alignCast(ptr));
            cleaned.* = true;
        }
    };

    var mock = MockRoundTripper{};
    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
    });
    defer client.deinit();

    var req = try Request.init(testing.allocator, "GET", "http://example.com/");
    defer req.deinit();

    try testing.expectEqual(@as(usize, 0), client.shared.active_requests);

    var resp = try client.do(&req);
    try testing.expectEqual(@as(usize, 1), mock.calls);
    try testing.expectEqual(@as(usize, 1), client.shared.active_requests);
    try testing.expect(!mock.cleaned);

    resp.deinit();
    try testing.expect(mock.cleaned);
    try testing.expectEqual(@as(usize, 0), client.shared.active_requests);
}

test "net/unit_tests/http/Client/do_follows_redirects_with_internal_request_hops" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const MockBody = struct {
        allocator: std.mem.Allocator,
        closed: *bool,

        pub fn read(_: *@This(), _: []u8) anyerror!usize {
            return 0;
        }

        pub fn close(self: *@This()) void {
            self.closed.* = true;
            self.allocator.destroy(self);
        }
    };

    const SeenRequest = struct {
        method: []u8,
        raw_url: []u8,
    };

    const MockRoundTripper = struct {
        allocator: std.mem.Allocator,
        seen: std.ArrayList(SeenRequest),
        first_closed: bool = false,
        calls: usize = 0,

        fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .seen = .{},
            };
        }

        fn deinit(self: *@This()) void {
            for (self.seen.items) |item| {
                self.allocator.free(item.method);
                self.allocator.free(item.raw_url);
            }
            self.seen.deinit(self.allocator);
        }

        pub fn roundTrip(self: *@This(), req: *const Request) anyerror!Response {
            try self.seen.append(self.allocator, .{
                .method = try self.allocator.dupe(u8, req.effectiveMethod()),
                .raw_url = try self.allocator.dupe(u8, req.url.raw),
            });

            self.calls += 1;
            if (self.calls == 1) {
                const body = try self.allocator.create(MockBody);
                body.* = .{
                    .allocator = self.allocator,
                    .closed = &self.first_closed,
                };
                return .{
                    .status_code = status.found,
                    .header = &.{Header.init(Header.location, "/next")},
                    .body_reader = ReadCloser.init(body),
                };
            }

            return .{
                .status_code = status.ok,
            };
        }
    };

    var mock = MockRoundTripper.init(testing.allocator);
    defer mock.deinit();

    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
    });
    defer client.deinit();

    var req = try Request.init(testing.allocator, "POST", "http://example.com/start");
    defer req.deinit();

    var resp = try client.do(&req);
    defer resp.deinit();

    try testing.expectEqual(@as(usize, 2), mock.calls);
    try testing.expect(mock.first_closed);
    try testing.expectEqualStrings("POST", mock.seen.items[0].method);
    try testing.expectEqualStrings("http://example.com/start", mock.seen.items[0].raw_url);
    try testing.expectEqualStrings("GET", mock.seen.items[1].method);
    try testing.expectEqualStrings("http://example.com/next", mock.seen.items[1].raw_url);
    try testing.expectEqualStrings("POST", req.effectiveMethod());
    try testing.expectEqualStrings("http://example.com/start", req.url.raw);
}

test "net/unit_tests/http/Client/do_returns_redirect_response_when_replay_is_not_possible" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const MockBody = struct {
        pub fn read(_: *@This(), _: []u8) anyerror!usize {
            return 0;
        }

        pub fn close(_: *@This()) void {}
    };

    const MockRoundTripper = struct {
        calls: usize = 0,

        pub fn roundTrip(self: *@This(), _: *const Request) anyerror!Response {
            self.calls += 1;
            return .{
                .status_code = status.temporary_redirect,
                .header = &.{Header.init(Header.location, "/preserve")},
            };
        }
    };

    var body = MockBody{};
    var req = try Request.init(testing.allocator, "POST", "http://example.com/upload");
    defer req.deinit();
    req = req.withBody(ReadCloser.init(&body));
    req.content_length = 3;

    var mock = MockRoundTripper{};
    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
    });
    defer client.deinit();

    var resp = try client.do(&req);
    defer resp.deinit();

    try testing.expectEqual(@as(usize, 1), mock.calls);
    try testing.expectEqual(status.temporary_redirect, resp.status_code);
}

test "net/unit_tests/http/Client/do_errors_when_redirect_limit_is_exceeded" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const MockRoundTripper = struct {
        calls: usize = 0,

        pub fn roundTrip(self: *@This(), _: *const Request) anyerror!Response {
            self.calls += 1;
            return .{
                .status_code = status.moved_permanently,
                .header = &.{Header.init(Header.location, "/loop")},
            };
        }
    };

    var mock = MockRoundTripper{};
    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
        .redirect_limit = 1,
    });
    defer client.deinit();

    var req = try Request.init(testing.allocator, "GET", "http://example.com/start");
    defer req.deinit();

    try testing.expectError(error.TooManyRedirects, client.do(&req));
    try testing.expectEqual(@as(usize, 2), mock.calls);
    try testing.expectEqual(@as(usize, 0), client.shared.active_requests);
}

test "net/unit_tests/http/Client/do_preserves_HEAD_across_found_redirect" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const SeenRequest = struct {
        method: []u8,
        raw_url: []u8,
    };

    const MockRoundTripper = struct {
        allocator: std.mem.Allocator,
        seen: std.ArrayList(SeenRequest),
        calls: usize = 0,

        fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .seen = .{},
            };
        }

        fn deinit(self: *@This()) void {
            for (self.seen.items) |item| {
                self.allocator.free(item.method);
                self.allocator.free(item.raw_url);
            }
            self.seen.deinit(self.allocator);
        }

        pub fn roundTrip(self: *@This(), req: *const Request) anyerror!Response {
            try self.seen.append(self.allocator, .{
                .method = try self.allocator.dupe(u8, req.effectiveMethod()),
                .raw_url = try self.allocator.dupe(u8, req.url.raw),
            });
            self.calls += 1;
            return if (self.calls == 1)
                .{
                    .status_code = status.found,
                    .header = &.{Header.init(Header.location, "/head-next")},
                }
            else
                .{
                    .status_code = status.ok,
                };
        }
    };

    var mock = MockRoundTripper.init(testing.allocator);
    defer mock.deinit();

    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
    });
    defer client.deinit();

    var req = try Request.init(testing.allocator, "HEAD", "http://example.com/head-start");
    defer req.deinit();

    var resp = try client.do(&req);
    defer resp.deinit();

    try testing.expectEqual(@as(usize, 2), mock.seen.items.len);
    try testing.expectEqualStrings("HEAD", mock.seen.items[0].method);
    try testing.expectEqualStrings("HEAD", mock.seen.items[1].method);
    try testing.expectEqualStrings("http://example.com/head-next", mock.seen.items[1].raw_url);
}

test "net/unit_tests/http/Client/get_and_head_are_thin_wrappers_over_do" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const SeenRequest = struct {
        method: []u8,
        raw_url: []u8,
    };

    const MockRoundTripper = struct {
        allocator: std.mem.Allocator,
        seen: std.ArrayList(SeenRequest),

        fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .seen = .{},
            };
        }

        fn deinit(self: *@This()) void {
            for (self.seen.items) |item| {
                self.allocator.free(item.method);
                self.allocator.free(item.raw_url);
            }
            self.seen.deinit(self.allocator);
        }

        pub fn roundTrip(self: *@This(), req: *const Request) anyerror!Response {
            try self.seen.append(self.allocator, .{
                .method = try self.allocator.dupe(u8, req.effectiveMethod()),
                .raw_url = try self.allocator.dupe(u8, req.url.raw),
            });
            return .{
                .status_code = status.ok,
                .request = req.*,
            };
        }
    };

    var mock = MockRoundTripper.init(testing.allocator);
    defer mock.deinit();

    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
    });
    defer client.deinit();

    var get_resp = try client.get("https://example.com/a");
    try testing.expectEqualStrings("GET", get_resp.request.?.effectiveMethod());
    try testing.expectEqualStrings("https://example.com/a", get_resp.request.?.url.raw);
    get_resp.deinit();

    var head_resp = try client.head("https://example.com/b");
    try testing.expectEqualStrings("HEAD", head_resp.request.?.effectiveMethod());
    try testing.expectEqualStrings("https://example.com/b", head_resp.request.?.url.raw);
    head_resp.deinit();

    try testing.expectEqual(@as(usize, 2), mock.seen.items.len);
    try testing.expectEqualStrings("GET", mock.seen.items[0].method);
    try testing.expectEqualStrings("https://example.com/a", mock.seen.items[0].raw_url);
    try testing.expectEqualStrings("HEAD", mock.seen.items[1].method);
    try testing.expectEqualStrings("https://example.com/b", mock.seen.items[1].raw_url);
    try testing.expectEqual(@as(usize, 0), client.shared.active_requests);
}

test "net/unit_tests/http/Client/resolveRedirectUrl_handles_relative_query_and_fragment_forms" {
    const std = @import("std");
    const testing = std.testing;

    const base = try url_mod.parse("https://example.com/dir/sub/index.html?old=1#frag");

    const relative = try resolveRedirectUrl(std, testing.allocator, base, "../next?q=1#new");
    defer testing.allocator.free(relative);
    try testing.expectEqualStrings("https://example.com/dir/next?q=1#new", relative);

    const query_only = try resolveRedirectUrl(std, testing.allocator, base, "?updated=1");
    defer testing.allocator.free(query_only);
    try testing.expectEqualStrings("https://example.com/dir/sub/index.html?updated=1", query_only);

    const fragment_only = try resolveRedirectUrl(std, testing.allocator, base, "#section");
    defer testing.allocator.free(fragment_only);
    try testing.expectEqualStrings("https://example.com/dir/sub/index.html?old=1#section", fragment_only);

    const authority_relative = try resolveRedirectUrl(std, testing.allocator, base, "//cdn.example.com/assets");
    defer testing.allocator.free(authority_relative);
    try testing.expectEqualStrings("https://cdn.example.com/assets", authority_relative);
}

test "net/unit_tests/http/Client/do_rejects_new_work_after_deinit_starts" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const MockRoundTripper = struct {
        pub fn roundTrip(_: *@This(), _: *const Request) anyerror!Response {
            return .{ .status_code = 204 };
        }
    };

    var mock = MockRoundTripper{};
    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
    });
    defer client.deinit();

    client.shared.mutex.lock();
    client.shared.deiniting = true;
    client.shared.mutex.unlock();

    var req = try Request.init(testing.allocator, "GET", "http://example.com/");
    defer req.deinit();

    try testing.expectError(error.Closed, client.do(&req));
    try testing.expectEqual(@as(usize, 0), client.shared.active_requests);
}

test "net/unit_tests/http/Client/deinit_waits_for_active_response_cleanup" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const MockRoundTripper = struct {
        pub fn roundTrip(_: *@This(), _: *const Request) anyerror!Response {
            return .{ .status_code = 200 };
        }
    };

    const Flags = struct {
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };

    const gen = struct {
        fn run(client: *HttpClient, flags: *Flags) void {
            flags.started.store(true, .seq_cst);
            client.deinit();
            flags.finished.store(true, .seq_cst);
        }
    };

    var mock = MockRoundTripper{};
    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
    });

    var req = try Request.init(testing.allocator, "GET", "http://example.com/");
    defer req.deinit();

    var resp = try client.do(&req);
    try testing.expectEqual(@as(usize, 1), client.shared.active_requests);

    var flags = Flags{};
    const thread = try std.Thread.spawn(.{}, gen.run, .{ &client, &flags });

    while (!flags.started.load(.seq_cst)) {
        std.Thread.yield() catch {};
    }
    for (0..16) |_| {
        std.Thread.yield() catch {};
    }
    try testing.expect(!flags.finished.load(.seq_cst));

    resp.deinit();
    thread.join();

    try testing.expect(flags.finished.load(.seq_cst));
}

test "net/unit_tests/http/Client/deinit_waits_for_redirect_chain_midflight" {
    const std = @import("std");
    const testing = std.testing;
    const HttpClient = Client(std);

    const InitialBody = struct {
        pub fn read(_: *@This(), _: []u8) anyerror!usize {
            return 0;
        }

        pub fn close(_: *@This()) void {}
    };

    const FreshBody = struct {
        pub fn read(_: *@This(), _: []u8) anyerror!usize {
            return 0;
        }

        pub fn close(self: *@This()) void {
            testing.allocator.destroy(self);
        }
    };

    const BlockingFactory = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        started: bool = false,
        allow_return: bool = false,

        pub fn getBody(self: *@This()) anyerror!ReadCloser {
            self.mutex.lock();
            self.started = true;
            self.cond.broadcast();
            while (!self.allow_return) self.cond.wait(&self.mutex);
            self.mutex.unlock();

            const body = try testing.allocator.create(FreshBody);
            body.* = .{};
            return ReadCloser.init(body);
        }

        fn waitUntilStarted(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.started) self.cond.wait(&self.mutex);
        }

        fn allow(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.allow_return = true;
            self.cond.broadcast();
        }
    };

    const MockRoundTripper = struct {
        calls: usize = 0,

        pub fn roundTrip(self: *@This(), _: *const Request) anyerror!Response {
            self.calls += 1;
            return if (self.calls == 1)
                .{
                    .status_code = status.temporary_redirect,
                    .header = &.{Header.init(Header.location, "/next")},
                }
            else
                .{
                    .status_code = status.ok,
                };
        }
    };

    const DoState = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        finished: bool = false,
        resp: ?Response = null,
        err: ?anyerror = null,
    };

    const DoTask = struct {
        fn run(client: *HttpClient, req: *Request, state: *DoState) void {
            const result = client.do(req);
            state.mutex.lock();
            defer state.mutex.unlock();
            if (result) |resp| {
                state.resp = resp;
            } else |err| {
                state.err = err;
            }
            state.finished = true;
            state.cond.broadcast();
        }
    };

    const DeinitState = struct {
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };

    const DeinitTask = struct {
        fn run(client: *HttpClient, state: *DeinitState) void {
            state.started.store(true, .seq_cst);
            client.deinit();
            state.finished.store(true, .seq_cst);
        }
    };

    var factory = BlockingFactory{};
    var mock = MockRoundTripper{};
    var client = try HttpClient.init(testing.allocator, .{
        .round_tripper = RoundTripper.init(&mock),
    });

    var initial_body = InitialBody{};
    var req = try Request.init(testing.allocator, "POST", "http://example.com/start");
    defer req.deinit();
    req = req.withBody(ReadCloser.init(&initial_body));
    req = req.withGetBody(Request.GetBody.init(&factory));
    req.content_length = 1;

    var do_state = DoState{};
    const do_thread = try std.Thread.spawn(.{}, DoTask.run, .{ &client, &req, &do_state });

    factory.waitUntilStarted();

    var deinit_state = DeinitState{};
    const deinit_thread = try std.Thread.spawn(.{}, DeinitTask.run, .{ &client, &deinit_state });

    while (!deinit_state.started.load(.seq_cst)) {
        std.Thread.yield() catch {};
    }
    for (0..16) |_| {
        std.Thread.yield() catch {};
    }
    try testing.expect(!deinit_state.finished.load(.seq_cst));

    factory.allow();
    do_thread.join();

    do_state.mutex.lock();
    try testing.expect(do_state.finished);
    try testing.expect(do_state.err == null);
    try testing.expect(do_state.resp != null);
    var resp = do_state.resp.?;
    do_state.mutex.unlock();

    try testing.expect(!deinit_state.finished.load(.seq_cst));

    resp.deinit();
    deinit_thread.join();

    try testing.expectEqual(@as(usize, 2), mock.calls);
    try testing.expect(deinit_state.finished.load(.seq_cst));
}
