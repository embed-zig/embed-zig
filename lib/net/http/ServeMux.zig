//! ServeMux — path-first HTTP request multiplexer.

const Request = @import("Request.zig");
const ResponseWriter = @import("ResponseWriter.zig").ResponseWriter;
const handler_mod = @import("Handler.zig");
const mux_common = @import("mux_common.zig");
const testing_api = @import("testing");

pub fn ServeMux(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Handler = handler_mod.Handler(lib);
    const HandlerFunc = handler_mod.HandlerFunc(lib);
    const Writer = ResponseWriter(lib);

    return struct {
        allocator: Allocator,
        routes: lib.ArrayList(Route) = .{},

        const Self = @This();

        const RouteKind = mux_common.RouteKind;

        const Route = struct {
            pattern: []u8,
            kind: RouteKind,
            handler: Handler,
        };

        pub const HandleError = Allocator.Error || error{
            DuplicatePattern,
            InvalidPattern,
        };

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.routes.items) |route| self.allocator.free(route.pattern);
            self.routes.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn handle(self: *Self, pattern: []const u8, route_handler: Handler) HandleError!void {
            const kind = mux_common.classifyPattern(pattern) orelse return error.InvalidPattern;
            if (self.hasPattern(pattern)) return error.DuplicatePattern;

            try self.routes.append(self.allocator, .{
                .pattern = try self.allocator.dupe(u8, pattern),
                .kind = kind,
                .handler = route_handler,
            });
        }

        pub fn handleFunc(self: *Self, pattern: []const u8, func: HandlerFunc) HandleError!void {
            try self.handle(pattern, Handler.fromFunc(func));
        }

        pub fn handler(self: *Self) Handler {
            return Handler.init(self);
        }

        pub fn serveHTTP(self: *Self, rw: *Writer, req: *Request) void {
            const path = mux_common.requestPath(req);
            const cleaned = mux_common.cleanPath(lib, self.allocator, path) catch path;
            const owns_cleaned = cleaned.ptr != path.ptr;
            defer if (owns_cleaned) self.allocator.free(cleaned);

            if (!lib.mem.eql(u8, cleaned, path)) {
                mux_common.redirectTo(lib, rw, cleaned);
                return;
            }

            if (self.needsTrailingSlashRedirect(cleaned)) {
                const target = mux_common.appendSlash(self.allocator, cleaned) catch {
                    mux_common.notFound(lib, rw);
                    return;
                };
                defer self.allocator.free(target);
                mux_common.redirectTo(lib, rw, target);
                return;
            }

            const route = self.bestRoute(cleaned) orelse {
                mux_common.notFound(lib, rw);
                return;
            };
            route.handler.serveHTTP(rw, req);
        }

        fn hasPattern(self: *const Self, pattern: []const u8) bool {
            for (self.routes.items) |route| {
                if (lib.mem.eql(u8, route.pattern, pattern)) return true;
            }
            return false;
        }

        fn bestRoute(self: *const Self, path: []const u8) ?Route {
            var best: ?Route = null;
            var best_len: usize = 0;
            for (self.routes.items) |route| {
                if (!matches(route, path)) continue;
                if (route.pattern.len >= best_len) {
                    best = route;
                    best_len = route.pattern.len;
                }
            }
            return best;
        }

        fn needsTrailingSlashRedirect(self: *const Self, path: []const u8) bool {
            if (path.len == 0 or path[path.len - 1] == '/') return false;
            const with_slash = mux_common.appendSlash(self.allocator, path) catch return false;
            defer self.allocator.free(with_slash);
            for (self.routes.items) |route| {
                if (route.kind == .subtree and lib.mem.eql(u8, route.pattern, with_slash)) return true;
            }
            return false;
        }

        fn matches(route: Route, path: []const u8) bool {
            return switch (route.kind) {
                .catch_all => true,
                .exact => lib.mem.eql(u8, route.pattern, path),
                .subtree => lib.mem.startsWith(u8, path, route.pattern),
            };
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Mux = ServeMux(lib);
            const H = handler_mod.Handler(lib);
            const Writer = ResponseWriter(lib);

            {
                const Demo = struct {
                    pub fn serveHTTP(_: *@This(), _: *Writer, _: *Request) void {}
                };

                var demo = Demo{};
                var mux = Mux.init(allocator);
                defer mux.deinit();

                try mux.handle("/hello", H.init(&demo));
                try testing.expectError(error.DuplicatePattern, mux.handle("/hello", H.init(&demo)));
            }

            {
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

                var state = State{};
                var root_handler = RootHandler{ .state = &state };
                var api_handler = ApiHandler{ .state = &state };

                var mux = Mux.init(allocator);
                defer mux.deinit();
                try mux.handle("/", H.init(&root_handler));
                try mux.handle("/api/", H.init(&api_handler));

                var req = try Request.init(allocator, "GET", "https://example.com/api/users");
                defer req.deinit();
                var writer = Writer.init(allocator, undefined, &req, false);
                defer writer.deinit();

                mux.serveHTTP(&writer, &req);
                try testing.expectEqualStrings("api", state.value);
            }
        }
    }.run);
}
