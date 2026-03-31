//! StaticServeMux — comptime-built HTTP request multiplexer.

const Request = @import("Request.zig");
const ResponseWriter = @import("ResponseWriter.zig").ResponseWriter;
const handler_mod = @import("Handler.zig");
const mux_common = @import("mux_common.zig");

pub fn StaticServeMux(comptime lib: type, comptime spec: anytype) type {
    if (validationError(spec)) |err| @compileError(err);

    const Handler = handler_mod.Handler(lib);
    const routes = comptime normalizeSpec(spec);
    const trie = comptime buildTrie(routes);
    const Writer = ResponseWriter(lib);

    return struct {
        handlers: [routes.len]Handler,

        const Self = @This();

        pub fn init(route_handlers: anytype) Self {
            return .{
                .handlers = coerceHandlers(route_handlers),
            };
        }

        pub fn handler(self: *Self) Handler {
            return Handler.init(self);
        }

        pub fn serveHTTP(self: *Self, rw: *Writer, req: *Request) void {
            const path = mux_common.requestPath(req);
            const cleaned = mux_common.cleanPath(lib, rw.allocator, path) catch path;
            const owns_cleaned = cleaned.ptr != path.ptr;
            defer if (owns_cleaned) rw.allocator.free(cleaned);

            if (!lib.mem.eql(u8, cleaned, path)) {
                mux_common.redirectTo(lib, rw, cleaned);
                return;
            }

            if (needsTrailingSlashRedirect(cleaned)) {
                const target = mux_common.appendSlash(rw.allocator, cleaned) catch {
                    mux_common.notFound(lib, rw);
                    return;
                };
                defer rw.allocator.free(target);
                mux_common.redirectTo(lib, rw, target);
                return;
            }

            const route_index = bestRoute(cleaned) orelse {
                mux_common.notFound(lib, rw);
                return;
            };
            self.handlers[route_index].serveHTTP(rw, req);
        }

        fn coerceHandlers(route_handlers: anytype) [routes.len]Handler {
            const Handlers = @TypeOf(route_handlers);
            const info = @typeInfo(Handlers);
            switch (info) {
                .array => |array_info| {
                    if (array_info.len != routes.len) {
                        @compileError("StaticServeMux.init expects " ++ comptimeIntToString(routes.len) ++ " handlers");
                    }
                },
                .@"struct" => |struct_info| {
                    if (!struct_info.is_tuple or struct_info.fields.len != routes.len) {
                        @compileError("StaticServeMux.init expects a handler tuple with " ++ comptimeIntToString(routes.len) ++ " entries");
                    }
                },
                else => @compileError("StaticServeMux.init expects an array or tuple of handlers"),
            }

            var out: [routes.len]Handler = undefined;
            inline for (route_handlers, 0..) |entry, idx| {
                out[idx] = coerceHandler(entry);
            }
            return out;
        }

        fn coerceHandler(route_handler: anytype) Handler {
            const T = @TypeOf(route_handler);
            if (T == Handler) return route_handler;

            return switch (@typeInfo(T)) {
                .pointer => |ptr| if (ptr.size == .one) switch (@typeInfo(ptr.child)) {
                    .@"fn" => Handler.fromFunc(route_handler),
                    else => Handler.init(route_handler),
                } else @compileError("StaticServeMux handlers must be Handler values, single-item pointers, or plain functions"),
                .@"fn" => Handler.fromFunc(route_handler),
                else => @compileError("StaticServeMux handlers must be Handler values, single-item pointers, or plain functions"),
            };
        }

        fn needsTrailingSlashRedirect(path: []const u8) bool {
            if (path.len == 0 or path[path.len - 1] == '/') return false;
            const node_index = lookupNode(path) orelse return false;
            return trie.nodes[node_index].subtree_handler_index != null;
        }

        fn bestRoute(path: []const u8) ?usize {
            var best = trie.nodes[0].catch_all_handler_index;
            var current_node: usize = 0;
            var iter = mux_common.SegmentIter.init(path);
            while (iter.next()) |segment| {
                const child = findChild(current_node, segment) orelse return best;
                current_node = child;
                if (trie.nodes[current_node].subtree_handler_index) |idx| best = idx;
            }
            if (!hasNonRootTrailingSlash(path)) {
                if (trie.nodes[current_node].exact_handler_index) |idx| return idx;
            }
            return best;
        }

        fn lookupNode(path: []const u8) ?usize {
            var current_node: usize = 0;
            var iter = mux_common.SegmentIter.init(path);
            while (iter.next()) |segment| {
                current_node = findChild(current_node, segment) orelse return null;
            }
            return current_node;
        }

        fn findChild(node_index: usize, segment: []const u8) ?usize {
            var edge_index = trie.nodes[node_index].first_child_edge;
            while (edge_index) |idx| : (edge_index = trie.edges[idx].next_sibling_edge) {
                const edge = trie.edges[idx];
                if (lib.mem.eql(u8, edge.segment, segment)) return edge.child_node_index;
            }
            return null;
        }

        fn hasNonRootTrailingSlash(path: []const u8) bool {
            return path.len > 1 and path[path.len - 1] == '/';
        }
    };
}

const NormalizedRoute = struct {
    pattern: []const u8,
    kind: mux_common.RouteKind,
};

const TrieNode = struct {
    first_child_edge: ?usize = null,
    exact_handler_index: ?usize = null,
    subtree_handler_index: ?usize = null,
    catch_all_handler_index: ?usize = null,
};

const TrieEdge = struct {
    segment: []const u8,
    child_node_index: usize,
    next_sibling_edge: ?usize = null,
};

fn validationError(comptime spec: anytype) ?[]const u8 {
    const len = comptime specLen(spec) catch return "StaticServeMux route spec must be an array or tuple";
    var patterns: [len][]const u8 = undefined;

    inline for (spec, 0..) |entry, idx| {
        const pattern = comptime patternFromEntry(entry) catch return "StaticServeMux route entries must be string literals or structs with a .pattern field";
        if (mux_common.classifyPattern(pattern) == null) {
            return "StaticServeMux route spec contains an invalid pattern";
        }
        patterns[idx] = pattern;
    }

    inline for (0..len) |i| {
        inline for (0..len) |j| {
            if (j <= i) continue;
            if (sliceEql(patterns[i], patterns[j])) {
                return "StaticServeMux route spec contains a duplicate pattern";
            }
        }
    }
    return null;
}

fn normalizeSpec(comptime spec: anytype) [specLen(spec) catch unreachable]NormalizedRoute {
    const len = comptime specLen(spec) catch unreachable;
    var routes: [len]NormalizedRoute = undefined;
    inline for (spec, 0..) |entry, idx| {
        const pattern = patternFromEntry(entry) catch unreachable;
        routes[idx] = .{
            .pattern = pattern,
            .kind = mux_common.classifyPattern(pattern) orelse unreachable,
        };
    }
    return routes;
}

fn specLen(comptime spec: anytype) !usize {
    return switch (@typeInfo(@TypeOf(spec))) {
        .array => |info| info.len,
        .@"struct" => |info| if (info.is_tuple)
            info.fields.len
        else
            error.InvalidSpecShape,
        else => error.InvalidSpecShape,
    };
}

fn patternFromEntry(comptime entry: anytype) ![]const u8 {
    const T = @TypeOf(entry);
    return switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .slice => entry,
            .one => switch (@typeInfo(info.child)) {
                .array => entry[0..],
                else => error.InvalidSpecEntry,
            },
            else => error.InvalidSpecEntry,
        },
        .array => entry[0..],
        .@"struct" => if (@hasField(T, "pattern"))
            patternFromEntry(entry.pattern)
        else
            error.InvalidSpecEntry,
        else => error.InvalidSpecEntry,
    };
}

fn BuildTrieResult(comptime routes: anytype) type {
    const max_nodes = 1 + totalSegmentCount(routes);
    const max_edges = if (max_nodes == 0) 0 else max_nodes - 1;
    return struct {
        nodes: [max_nodes]TrieNode,
        edges: [max_edges]TrieEdge,
    };
}

fn buildTrie(comptime routes: anytype) BuildTrieResult(routes) {
    const Result = BuildTrieResult(routes);
    const max_nodes = 1 + totalSegmentCount(routes);
    const max_edges = if (max_nodes == 0) 0 else max_nodes - 1;
    var nodes: [max_nodes]TrieNode = [_]TrieNode{.{}} ** max_nodes;
    var edges: [max_edges]TrieEdge = [_]TrieEdge{.{
        .segment = "",
        .child_node_index = 0,
        .next_sibling_edge = null,
    }} ** max_edges;
    var node_count: usize = 1;
    var edge_count: usize = 0;

    inline for (routes, 0..) |route, route_index| {
        switch (route.kind) {
            .catch_all => {
                nodes[0].catch_all_handler_index = route_index;
            },
            .exact, .subtree => {
                var current_node: usize = 0;
                var iter = mux_common.SegmentIter.init(route.pattern);
                while (iter.next()) |segment| {
                    current_node = findOrCreateChild(&nodes, &edges, &node_count, &edge_count, current_node, segment);
                }

                switch (route.kind) {
                    .exact => nodes[current_node].exact_handler_index = route_index,
                    .subtree => nodes[current_node].subtree_handler_index = route_index,
                    .catch_all => unreachable,
                }
            },
        }
    }

    return Result{
        .nodes = nodes,
        .edges = edges,
    };
}

fn findOrCreateChild(
    nodes: anytype,
    edges: anytype,
    node_count: *usize,
    edge_count: *usize,
    parent_node_index: usize,
    segment: []const u8,
) usize {
    var edge_index = nodes[parent_node_index].first_child_edge;
    while (edge_index) |idx| : (edge_index = edges[idx].next_sibling_edge) {
        if (sliceEql(edges[idx].segment, segment)) return edges[idx].child_node_index;
    }

    const child_node_index = node_count.*;
    node_count.* += 1;
    nodes[child_node_index] = .{};

    const new_edge_index = edge_count.*;
    edge_count.* += 1;
    edges[new_edge_index] = .{
        .segment = segment,
        .child_node_index = child_node_index,
        .next_sibling_edge = nodes[parent_node_index].first_child_edge,
    };
    nodes[parent_node_index].first_child_edge = new_edge_index;
    return child_node_index;
}

fn totalSegmentCount(comptime routes: anytype) usize {
    var total: usize = 0;
    inline for (routes) |route| {
        if (route.kind == .catch_all) continue;
        var iter = mux_common.SegmentIter.init(route.pattern);
        while (iter.next()) |_| total += 1;
    }
    return total;
}

fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (lhs != rhs) return false;
    }
    return true;
}

fn comptimeIntToString(comptime value: usize) []const u8 {
    return comptime blk: {
        var n = value;
        var digits: usize = 1;
        while (n >= 10) : (n /= 10) digits += 1;

        var buf: [digits]u8 = undefined;
        var remaining = value;
        var idx = digits;
        while (idx != 0) {
            idx -= 1;
            buf[idx] = @as(u8, @intCast('0' + (remaining % 10)));
            remaining /= 10;
        }
        break :blk buf[0..];
    };
}

test "net/unit_tests/http/StaticServeMux/validation_reports_invalid_and_duplicate_patterns" {
    const std = @import("std");

    try std.testing.expect(validationError(.{"hello"}) != null);
    try std.testing.expect(validationError(.{
        .{ .pattern = "/dup" },
        "/dup",
    }) != null);
    try std.testing.expect(validationError(.{
        .{ .pattern = "/" },
        .{ .pattern = "/api/" },
    }) == null);
}

test "net/unit_tests/http/StaticServeMux/handler_prefers_longest_match_and_catch_all" {
    const std = @import("std");
    const Writer = ResponseWriter(std);
    const Mux = StaticServeMux(std, .{
        "/",
        "/api/",
        "/api/users",
    });

    const State = struct {
        value: []const u8 = "",
    };

    const RootHandler = struct {
        state: *State,
        pub fn serveHTTP(self: *@This(), _: *Writer, _: *Request) void {
            self.state.value = "root";
        }
    };

    const ApiHandler = struct {
        state: *State,
        pub fn serveHTTP(self: *@This(), _: *Writer, _: *Request) void {
            self.state.value = "api";
        }
    };

    const UsersHandler = struct {
        state: *State,
        pub fn serveHTTP(self: *@This(), _: *Writer, _: *Request) void {
            self.state.value = "users";
        }
    };

    var state = State{};
    var root_handler = RootHandler{ .state = &state };
    var api_handler = ApiHandler{ .state = &state };
    var users_handler = UsersHandler{ .state = &state };
    var mux = Mux.init(.{ &root_handler, &api_handler, &users_handler });

    var req = try Request.init(std.testing.allocator, "GET", "https://example.com/api/users");
    defer req.deinit();
    var writer = Writer.init(std.testing.allocator, undefined, &req, false);
    defer writer.deinit();
    mux.serveHTTP(&writer, &req);
    try std.testing.expectEqualStrings("users", state.value);

    var miss_req = try Request.init(std.testing.allocator, "GET", "https://example.com/missing");
    defer miss_req.deinit();
    var miss_writer = Writer.init(std.testing.allocator, undefined, &miss_req, false);
    defer miss_writer.deinit();
    mux.serveHTTP(&miss_writer, &miss_req);
    try std.testing.expectEqualStrings("root", state.value);
}

test "net/unit_tests/http/StaticServeMux/exact_and_subtree_share_leaf_correctly" {
    const std = @import("std");
    const Writer = ResponseWriter(std);
    const ExactOnlyMux = StaticServeMux(std, .{
        "/api",
    });
    const ExactAndSubtreeMux = StaticServeMux(std, .{
        "/api",
        "/api/",
    });

    const State = struct {
        value: []const u8 = "",
    };

    const ExactHandler = struct {
        state: *State,
        pub fn serveHTTP(self: *@This(), _: *Writer, _: *Request) void {
            self.state.value = "exact";
        }
    };

    const SubtreeHandler = struct {
        state: *State,
        pub fn serveHTTP(self: *@This(), _: *Writer, _: *Request) void {
            self.state.value = "subtree";
        }
    };

    var state = State{};
    var exact_handler = ExactHandler{ .state = &state };
    var exact_only_mux = ExactOnlyMux.init(.{&exact_handler});

    var exact_req = try Request.init(std.testing.allocator, "GET", "https://example.com/api");
    defer exact_req.deinit();
    var exact_writer = Writer.init(std.testing.allocator, undefined, &exact_req, false);
    defer exact_writer.deinit();
    exact_only_mux.serveHTTP(&exact_writer, &exact_req);
    try std.testing.expectEqualStrings("exact", state.value);

    var subtree_handler = SubtreeHandler{ .state = &state };
    var pair_mux = ExactAndSubtreeMux.init(.{ &exact_handler, &subtree_handler });

    var subtree_req = try Request.init(std.testing.allocator, "GET", "https://example.com/api/");
    defer subtree_req.deinit();
    var subtree_writer = Writer.init(std.testing.allocator, undefined, &subtree_req, false);
    defer subtree_writer.deinit();
    pair_mux.serveHTTP(&subtree_writer, &subtree_req);
    try std.testing.expectEqualStrings("subtree", state.value);
}

test "net/unit_tests/http/StaticServeMux/redirect_and_not_found_match_dynamic_mux" {
    const std = @import("std");
    const Conn = @import("../Conn.zig");
    const Writer = ResponseWriter(std);
    const DynamicMux = @import("ServeMux.zig").ServeMux(std);
    const StaticMux = StaticServeMux(std, .{
        "/redirect/",
        "/exact",
    });

    const MockConn = struct {
        allocator: std.mem.Allocator,
        writes: std.ArrayList(u8),

        fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
            return .{
                .allocator = allocator,
                .writes = try std.ArrayList(u8).initCapacity(allocator, 0),
            };
        }

        pub fn read(_: *@This(), _: []u8) Conn.ReadError!usize {
            return error.EndOfStream;
        }

        pub fn write(self: *@This(), buf: []const u8) Conn.WriteError!usize {
            self.writes.appendSlice(self.allocator, buf) catch return error.Unexpected;
            return buf.len;
        }

        pub fn close(_: *@This()) void {}
        pub fn deinit(self: *@This()) void {
            self.writes.deinit(self.allocator);
        }
        pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
        pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
    };

    const SinkHandler = struct {
        pub fn serveHTTP(_: *@This(), rw: *Writer, _: *Request) void {
            rw.setHeader("Content-Length", "2") catch return;
            _ = rw.write("ok") catch {};
        }
    };

    const Captured = struct {
        status_line: []u8,
        location: ?[]const u8,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.status_line);
            if (self.location) |loc| allocator.free(loc);
        }
    };

    const captureResponse = struct {
        fn run(mux: anytype, allocator: std.mem.Allocator, url: []const u8) !Captured {
            var raw = try MockConn.init(allocator);
            defer raw.deinit();
            var req = try Request.init(allocator, "GET", url);
            defer req.deinit();
            var writer = Writer.init(allocator, Conn.init(&raw), &req, false);
            defer writer.deinit();

            mux.serveHTTP(&writer, &req);
            try writer.finish();

            const head = raw.writes.items;
            const first_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.TestUnexpectedResult;
            const header_end = std.mem.indexOf(u8, head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
            const status_line = head[0..first_end];
            const location = headerValue(head[0..header_end], "Location");
            return .{
                .status_line = try allocator.dupe(u8, status_line),
                .location = if (location) |loc| try allocator.dupe(u8, loc) else null,
            };
        }

        fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
            var start: usize = 0;
            while (start < head.len) {
                const line_end = std.mem.indexOfScalarPos(u8, head, start, '\n') orelse head.len;
                const line = std.mem.trimRight(u8, head[start..line_end], "\r");
                if (line.len == 0) return null;
                if (std.mem.startsWith(u8, line, name) and line.len > name.len + 1 and line[name.len] == ':') {
                    return std.mem.trimLeft(u8, line[name.len + 1 ..], " ");
                }
                start = @min(line_end + 1, head.len);
            }
            return null;
        }
    };

    var dynamic = DynamicMux.init(std.testing.allocator);
    defer dynamic.deinit();
    var sink_a = SinkHandler{};
    var sink_b = SinkHandler{};
    try dynamic.handle("/redirect/", handler_mod.Handler(std).init(&sink_a));
    try dynamic.handle("/exact", handler_mod.Handler(std).init(&sink_b));

    var static_sink_a = SinkHandler{};
    var static_sink_b = SinkHandler{};
    var statik = StaticMux.init(.{ &static_sink_a, &static_sink_b });

    var cleaned_dynamic = try captureResponse.run(&dynamic, std.testing.allocator, "https://example.com/redirect/../redirect");
    defer cleaned_dynamic.deinit(std.testing.allocator);
    var cleaned_static = try captureResponse.run(&statik, std.testing.allocator, "https://example.com/redirect/../redirect");
    defer cleaned_static.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(cleaned_dynamic.status_line, cleaned_static.status_line);
    try std.testing.expectEqualStrings(cleaned_dynamic.location orelse "", cleaned_static.location orelse "");

    var slash_dynamic = try captureResponse.run(&dynamic, std.testing.allocator, "https://example.com/redirect");
    defer slash_dynamic.deinit(std.testing.allocator);
    var slash_static = try captureResponse.run(&statik, std.testing.allocator, "https://example.com/redirect");
    defer slash_static.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(slash_dynamic.status_line, slash_static.status_line);
    try std.testing.expectEqualStrings(slash_dynamic.location orelse "", slash_static.location orelse "");

    var missing_dynamic = try captureResponse.run(&dynamic, std.testing.allocator, "https://example.com/missing");
    defer missing_dynamic.deinit(std.testing.allocator);
    var missing_static = try captureResponse.run(&statik, std.testing.allocator, "https://example.com/missing");
    defer missing_static.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(missing_dynamic.status_line, missing_static.status_line);
    try std.testing.expectEqualStrings(missing_dynamic.location orelse "", missing_static.location orelse "");
}
