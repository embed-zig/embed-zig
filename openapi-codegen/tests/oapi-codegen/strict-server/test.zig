const testing = embed.testing;
const std = @import("std");
const openapi = @import("openapi");
const codegen = @import("codegen");
const net_mod = embed.net;

const embed = @import("embed");
const lib = @import("embed_std").std;
const Context = embed.context.Context;
const net = embed.net.make(lib);

const ClientApi = blk: {
    const spec = openapi.json.parse(@embedFile("spec.json"));
    const files: openapi.Files = .{
        .items = &.{
            .{
                .name = "spec.json",
                .spec = spec,
            },
        },
    };
    break :blk codegen.client.make(lib, files);
};

const ServerApi = blk: {
    const spec = openapi.json.parse(@embedFile("spec.json"));
    const files: openapi.Files = .{
        .items = &.{
            .{
                .name = "spec.json",
                .spec = spec,
            },
        },
    };
    break :blk codegen.server.make(lib, files);
};

fn readAllReadCloser(allocator: lib.mem.Allocator, reader: net.http.ReadCloser) ![]u8 {
    defer reader.close();
    var list = try lib.ArrayList(u8).initCapacity(allocator, 0);
    defer list.deinit(allocator);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

const FixedBufferBody = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn read(self: *@This(), buffer: []u8) !usize {
        const remaining = self.bytes[self.offset..];
        const amount = @min(buffer.len, remaining.len);
        @memcpy(buffer[0..amount], remaining[0..amount]);
        self.offset += amount;
        return amount;
    }

    pub fn close(_: *@This()) void {}
};

fn specRunner() testing.TestRunner {
    const Runner = struct {
        pub fn init(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn run(_: *@This(), t: *testing.T, allocator: std.mem.Allocator) bool {
            checkFixture(allocator) catch |e| {
                t.logFatal(@errorName(e));
                return false;
            };
            return true;
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}

        fn checkFixture(allocator: std.mem.Allocator) !void {
            const Spec = openapi.Spec;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const spec = try openapi.json.parseAlloc(a, @embedFile("spec.json"));
            try std.testing.expectEqualStrings("3.0.0", spec.openapi);
            try std.testing.expectEqualStrings("Strict server examples", spec.info.title);
            try std.testing.expectEqualStrings("1.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 14), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/json") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("JSONExample", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/urlencoded") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("URLEncodedExample", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/multipart") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("MultipartExample", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/multipart-related") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("MultipartRelatedExample", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/text") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("TextExample", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/unknown") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("UnknownExample", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/multiple") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("MultipleRequestAndResponseTypes", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/with-headers") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("HeadersExample", post_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 2), post_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/reusable-responses") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("ReusableResponses", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/unspecified-content-type") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("UnspecifiedContentType", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/required-json-body") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("RequiredJSONBody", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/required-text-body") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("RequiredTextBody", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/reserved-go-keyword-parameters/{type}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("ReservedGoKeywordParameters", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/with-union") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("UnionExample", post_op.operation_id orelse return error.FixtureMismatch);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 1), components.schemas.len);
            const _sor_example = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "example") orelse return error.FixtureMismatch;
            switch (_sor_example) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}

const AppContext = struct {
    call_count: usize = 0,
    raw_call_count: usize = 0,
};

const Handlers = struct {
    fn JSONExample(ctx_ptr: *anyopaque, req_ctx: Context, allocator: lib.mem.Allocator, args: ServerApi.operations.JSONExample.Args) !ServerApi.operations.JSONExample.Response {
        _ = req_ctx;
        _ = allocator;
        const ctx: *AppContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.call_count += 1;

        if (std.mem.eql(u8, args.body.?.value.?, "boom")) {
            return .{ .status_400 = {} };
        }

        return .{ .status_200 = .{ .value = "ok" } };
    }

    fn TextExample(ctx_ptr: *anyopaque, req_ctx: Context, allocator: lib.mem.Allocator, args: ServerApi.operations.TextExample.Args) !ServerApi.operations.TextExample.Response {
        _ = req_ctx;
        const ctx: *AppContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.raw_call_count += 1;
        const reader = args.body orelse return error.MissingBody;
        const echoed = try readAllReadCloser(allocator, reader);
        return .{ .status_200 = echoed };
    }

    fn UnknownExample(ctx_ptr: *anyopaque, req_ctx: Context, allocator: lib.mem.Allocator, args: ServerApi.operations.UnknownExample.Args) !ServerApi.operations.UnknownExample.Response {
        _ = req_ctx;
        const ctx: *AppContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.raw_call_count += 1;
        const reader = args.body orelse return error.MissingBody;
        const echoed = try readAllReadCloser(allocator, reader);
        return .{ .status_200 = echoed };
    }
};

const ServerRun = struct {
    listener: net_mod.Listener,
    port: u16,
    server_err: ?anyerror = null,
    thread: lib.Thread,

    fn stop(self: *@This(), server: *ServerApi) !void {
        self.listener.close();
        server.close();
        self.thread.join();
        defer self.listener.deinit();
        if (self.server_err) |err| {
            if (err != error.ServerClosed) return err;
        }
    }
};

fn startServer(server: *ServerApi) !ServerRun {
    const listener = try net.listen(std.testing.allocator, .{
        .address = net_mod.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0),
    });
    const tcp_listener = try listener.as(net.TcpListener);
    const port = try tcp_listener.port();

    var run = ServerRun{
        .listener = listener,
        .port = port,
        .thread = undefined,
    };
    run.thread = try lib.Thread.spawn(.{}, struct {
        fn exec(s: *ServerApi, ln: net_mod.Listener, err: *?anyerror) void {
            s.serve(ln) catch |serve_err| {
                err.* = serve_err;
            };
        }
    }.exec, .{ server, listener, &run.server_err });
    return run;
}

fn run_generated_client_returns_status_union_responses(t: *testing.T, allocator: std.mem.Allocator) !void {
    _ = t;
    var ctx_ns = try embed.context.make(lib).init(allocator);
    defer ctx_ns.deinit();
    const bg = ctx_ns.background();

    var ctx = AppContext{};
    var server = try ServerApi.init(allocator, &ctx, .{
        .JSONExample = Handlers.JSONExample,
        .TextExample = Handlers.TextExample,
        .UnknownExample = Handlers.UnknownExample,
    });
    defer server.deinit();

    var run_inner = try startServer(&server);
    defer run_inner.stop(&server) catch {};

    const base_url = try lib.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{run_inner.port});
    defer allocator.free(base_url);

    var transport = try net.http.Transport.init(allocator, .{});
    defer transport.deinit();
    var http_client = try net.http.Client.init(allocator, .{
        .round_tripper = transport.roundTripper(),
    });
    defer http_client.deinit();

    var api = try ClientApi.init(.{
        .allocator = allocator,
        .http_client = &http_client,
        .base_url = base_url,
    });
    defer api.deinit();

    const ok = try api.operations.JSONExample.send(bg, allocator, .{
        .body = ClientApi.models.example{
            .value = "hello",
        },
    });
    defer api.operations.JSONExample.deinitResponse(ok);
    switch (ok.value) {
        .status_200 => |parsed| try std.testing.expectEqualStrings("ok", parsed.value.value.?),
        else => return error.UnexpectedStatus,
    }

    const bad_request = try api.operations.JSONExample.send(bg, allocator, .{
        .body = ClientApi.models.example{
            .value = "boom",
        },
    });
    defer api.operations.JSONExample.deinitResponse(bad_request);
    switch (bad_request.value) {
        .status_400 => {},
        else => return error.UnexpectedStatus,
    }

    try std.testing.expectEqual(@as(usize, 2), ctx.call_count);
}

fn run_generated_client_and_server_exchange_raw_request_and_response(t: *testing.T, allocator: std.mem.Allocator) !void {
    _ = t;
    var ctx_ns = try embed.context.make(lib).init(allocator);
    defer ctx_ns.deinit();
    const bg = ctx_ns.background();

    var ctx = AppContext{};
    var server = try ServerApi.init(allocator, &ctx, .{
        .JSONExample = Handlers.JSONExample,
        .TextExample = Handlers.TextExample,
        .UnknownExample = Handlers.UnknownExample,
    });
    defer server.deinit();

    var run_inner = try startServer(&server);
    defer run_inner.stop(&server) catch {};

    const base_url = try lib.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{run_inner.port});
    defer allocator.free(base_url);

    var transport = try net.http.Transport.init(allocator, .{});
    defer transport.deinit();
    var http_client = try net.http.Client.init(allocator, .{
        .round_tripper = transport.roundTripper(),
    });
    defer http_client.deinit();

    var api = try ClientApi.init(.{
        .allocator = allocator,
        .http_client = &http_client,
        .base_url = base_url,
    });
    defer api.deinit();

    var text_body = FixedBufferBody{ .bytes = "ping" };
    const text = try api.operations.TextExample.send(bg, allocator, .{
        .body = net.http.ReadCloser.init(&text_body),
    });
    defer api.operations.TextExample.deinitResponse(text);
    switch (text.value) {
        .status_200 => |reader| {
            defer reader.close();
            var buf: [64]u8 = undefined;
            var len: usize = 0;
            while (len < buf.len) {
                const n = try reader.read(buf[len..]);
                if (n == 0) break;
                len += n;
            }
            try std.testing.expectEqualStrings("ping", buf[0..len]);
        },
        else => return error.UnexpectedStatus,
    }

    var unknown_body = FixedBufferBody{ .bytes = "bytes" };
    const unknown = try api.operations.UnknownExample.send(bg, allocator, .{
        .body = net.http.ReadCloser.init(&unknown_body),
    });
    defer api.operations.UnknownExample.deinitResponse(unknown);
    switch (unknown.value) {
        .status_200 => |reader| {
            defer reader.close();
            var buf: [64]u8 = undefined;
            var len: usize = 0;
            while (len < buf.len) {
                const n = try reader.read(buf[len..]);
                if (n == 0) break;
                len += n;
            }
            try std.testing.expectEqualStrings("bytes", buf[0..len]);
        },
        else => return error.UnexpectedStatus,
    }

    try std.testing.expectEqual(@as(usize, 2), ctx.raw_call_count);
}

fn run_generated_client_closes_raw_request_stream_on_transport_error(t: *testing.T, allocator: std.mem.Allocator) !void {
    _ = t;
    var ctx_ns = try embed.context.make(lib).init(allocator);
    defer ctx_ns.deinit();
    const bg = ctx_ns.background();

    const CloseTrackingBody = struct {
        closed: *bool,
        payload: []const u8 = "boom",
        offset: usize = 0,

        pub fn read(self: *@This(), buffer: []u8) !usize {
            const remaining = self.payload[self.offset..];
            const amount = @min(buffer.len, remaining.len);
            @memcpy(buffer[0..amount], remaining[0..amount]);
            self.offset += amount;
            return amount;
        }

        pub fn close(self: *@This()) void {
            self.closed.* = true;
        }
    };

    const FailingRoundTripper = struct {
        pub fn roundTrip(_: *@This(), _: *const net.http.Request) anyerror!net.http.Response {
            return error.TransportBoom;
        }
    };

    var transport = FailingRoundTripper{};
    var http_client = try net.http.Client.init(allocator, .{
        .round_tripper = net.http.RoundTripper.init(&transport),
    });
    defer http_client.deinit();

    var api = try ClientApi.init(.{
        .allocator = allocator,
        .http_client = &http_client,
        .base_url = "http://example.test",
    });
    defer api.deinit();

    var closed = false;
    var body = CloseTrackingBody{ .closed = &closed };

    try std.testing.expectError(error.TransportBoom, api.operations.TextExample.send(bg, allocator, .{
        .body = net.http.ReadCloser.init(&body),
    }));
    try std.testing.expect(closed);
}

pub fn TestRunner() testing.TestRunner {
    const Runner = struct {
        pub fn init(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn run(_: *@This(), t: *testing.T, allocator: std.mem.Allocator) bool {
            _ = allocator;
            t.run("parse, roundtrip, and validate structure", specRunner());
            t.run("generated client returns status union responses", testing.TestRunner.fromFn(std, 1024 * 1024, run_generated_client_returns_status_union_responses));
            t.run("generated client and server exchange raw request and response", testing.TestRunner.fromFn(std, 1024 * 1024, run_generated_client_and_server_exchange_raw_request_and_response));
            t.run("generated client closes raw request stream on transport error", testing.TestRunner.fromFn(std, 1024 * 1024, run_generated_client_closes_raw_request_stream_on_transport_error));
            return t.wait();
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}
