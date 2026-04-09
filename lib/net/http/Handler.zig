//! Handler — type-erased HTTP request handler.
//!
//! Mirrors the conceptual role of Go's `http.Handler`, but follows the repo's
//! runtime-contract style.

const Request = @import("Request.zig");
const response_writer_mod = @import("ResponseWriter.zig");
const testing_api = @import("testing");

pub fn HandlerFunc(comptime lib: type) type {
    return *const fn (rw: *response_writer_mod.ResponseWriter(lib), req: *Request) void;
}

pub fn Handler(comptime lib: type) type {
    const ResponseWriter = response_writer_mod.ResponseWriter(lib);
    const Fn = HandlerFunc(lib);

    return union(enum) {
        erased: Erased,
        function: Fn,

        const Self = @This();

        pub const VTable = struct {
            serveHTTP: *const fn (ptr: *anyopaque, rw: *ResponseWriter, req: *Request) void,
        };

        pub const Erased = struct {
            ptr: *anyopaque,
            vtable: *const VTable,
        };

        pub fn serveHTTP(self: Self, rw: *ResponseWriter, req: *Request) void {
            switch (self) {
                .erased => |erased| erased.vtable.serveHTTP(erased.ptr, rw, req),
                .function => |func| func(rw, req),
            }
        }

        pub fn init(pointer: anytype) Self {
            const Ptr = @TypeOf(pointer);
            const info = @typeInfo(Ptr);
            if (info != .pointer or info.pointer.size != .one)
                @compileError("Handler.init expects a single-item pointer");

            const Impl = info.pointer.child;
            const gen = struct {
                fn serveHTTPFn(ptr: *anyopaque, rw: *ResponseWriter, req: *Request) void {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    self.serveHTTP(rw, req);
                }

                const vtable = VTable{
                    .serveHTTP = serveHTTPFn,
                };
            };

            return .{
                .erased = .{
                    .ptr = pointer,
                    .vtable = &gen.vtable,
                },
            };
        }

        pub fn fromFunc(func: Fn) Self {
            return .{ .function = func };
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 0, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Writer = response_writer_mod.ResponseWriter(lib);
            const H = Handler(lib);

            const Counter = struct {
                var calls: usize = 0;
                fn run(_: *Writer, _: *Request) void {
                    calls += 1;
                }
            };

            Counter.calls = 0;
            var writer = Writer.init(allocator, undefined, null, false);
            defer writer.deinit();
            var req = try Request.init(allocator, "GET", "https://example.com");
            defer req.deinit();

            const handler = H.fromFunc(Counter.run);
            handler.serveHTTP(&writer, &req);
            try testing.expectEqual(@as(usize, 1), Counter.calls);
        }
    }.run);
}
