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

pub const Phase = enum {
    spec,
    typed_requests,
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
            try std.testing.expectEqualStrings("3.0.1", spec.openapi);
            try std.testing.expectEqualStrings("Test Server", spec.info.title);
            try std.testing.expectEqualStrings("1.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 10), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/response-with-reference") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getResponseWithReference", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/reserved-keyword") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getReservedKeyword", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/every-type-optional") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getEveryTypeOptional", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/get-simple") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getSimple", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/get-with-type/{content_type}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getWithContentType", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/get-with-references/{global_argument}/{argument}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getWithReferences", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/get-with-args") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getWithArgs", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 3), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/resource/{argument}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("createResource", post_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), post_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/resource2/{inline_argument}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("createResource2", post_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 2), post_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/resource3/{fallthrough}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const put_op = p_it.put orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("updateResource3", put_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), put_op.parameters.len);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 6), components.schemas.len);
            const _sor_ThisShouldBePruned = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "ThisShouldBePruned") orelse return error.FixtureMismatch;
            switch (_sor_ThisShouldBePruned) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_some_object = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "some_object") orelse return error.FixtureMismatch;
            switch (_sor_some_object) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_Resource = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Resource") orelse return error.FixtureMismatch;
            switch (_sor_Resource) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_EveryTypeRequired = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "EveryTypeRequired") orelse return error.FixtureMismatch;
            switch (_sor_EveryTypeRequired) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 16), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 15), sch.required.len);
                },
            }
            const _sor_EveryTypeOptional = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "EveryTypeOptional") orelse return error.FixtureMismatch;
            switch (_sor_EveryTypeOptional) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 15), sch.properties.len);
                },
            }
            const _sor_ReservedKeyword = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "ReservedKeyword") orelse return error.FixtureMismatch;
            switch (_sor_ReservedKeyword) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
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
};

const Handlers = struct {
    fn getSimple(ctx_ptr: *anyopaque, req_ctx: Context, allocator: lib.mem.Allocator, args: ServerApi.operations.getSimple.Args) !ServerApi.operations.getSimple.Response {
        _ = req_ctx;
        _ = allocator;
        const ctx: *AppContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.call_count += 1;
        _ = args;
        return .{ .status_200 = .{ .name = "simple" } };
    }

    fn getWithReferences(ctx_ptr: *anyopaque, req_ctx: Context, allocator: lib.mem.Allocator, args: ServerApi.operations.getWithReferences.Args) !ServerApi.operations.getWithReferences.Response {
        _ = req_ctx;
        _ = allocator;
        const ctx: *AppContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.call_count += 1;
        try std.testing.expectEqual(@as(i64, 123), args.path.global_argument);
        try std.testing.expectEqualStrings("abc", args.path.argument);
        return .{ .status_200 = .{ .name = "refs" } };
    }

    fn getWithArgs(ctx_ptr: *anyopaque, req_ctx: Context, allocator: lib.mem.Allocator, args: ServerApi.operations.getWithArgs.Args) !ServerApi.operations.getWithArgs.Response {
        _ = req_ctx;
        _ = allocator;
        const ctx: *AppContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.call_count += 1;
        try std.testing.expect(args.query.optional_argument == null);
        try std.testing.expectEqual(@as(i64, 7), args.query.required_argument);
        try std.testing.expectEqual(@as(?i32, 11), args.header.header_argument);
        return .{ .status_200 = .{ .name = "args" } };
    }

    fn createResource2(ctx_ptr: *anyopaque, req_ctx: Context, allocator: lib.mem.Allocator, args: ServerApi.operations.createResource2.Args) !ServerApi.operations.createResource2.Response {
        _ = req_ctx;
        _ = allocator;
        const ctx: *AppContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.call_count += 1;
        try std.testing.expectEqual(@as(isize, 9), args.path.inline_argument);
        try std.testing.expectEqual(@as(?isize, 3), args.query.inline_query_argument);
        try std.testing.expectEqualStrings("demo", args.body.?.name);
        try std.testing.expectEqual(@as(f32, 1.5), args.body.?.value);
        return .{ .status_200 = .{ .name = "created" } };
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

fn run_generated_client_sends_typed_requests(t: *testing.T, allocator: std.mem.Allocator) !void {
    _ = t;
    _ = allocator;
    var ctx_ns = try embed.context.make(lib).init(std.testing.allocator);
    defer ctx_ns.deinit();
    const bg = ctx_ns.background();

    var ctx = AppContext{};
    var server = try ServerApi.init(std.testing.allocator, &ctx, .{
        .getSimple = Handlers.getSimple,
        .getWithReferences = Handlers.getWithReferences,
        .getWithArgs = Handlers.getWithArgs,
        .createResource2 = Handlers.createResource2,
    });
    defer server.deinit();

    var run_inner = try startServer(&server);
    defer run_inner.stop(&server) catch {};

    const base_url = try lib.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{run_inner.port});
    defer std.testing.allocator.free(base_url);

    var transport = try net.http.Transport.init(std.testing.allocator, .{});
    defer transport.deinit();
    var http_client = try net.http.Client.init(std.testing.allocator, .{
        .round_tripper = transport.roundTripper(),
    });
    defer http_client.deinit();

    var api = try ClientApi.init(.{
        .allocator = std.testing.allocator,
        .http_client = &http_client,
        .base_url = base_url,
    });
    defer api.deinit();

    const simple = try api.operations.getSimple.send(bg, std.testing.allocator, .{});
    defer api.operations.getSimple.deinitResponse(simple);
    switch (simple.value) {
        .status_200 => |parsed| try std.testing.expectEqualStrings("simple", parsed.value.name),
    }

    const references = try api.operations.getWithReferences.send(bg, std.testing.allocator, .{
        .path = .{
            .global_argument = 123,
            .argument = "abc",
        },
    });
    defer api.operations.getWithReferences.deinitResponse(references);
    switch (references.value) {
        .status_200 => |parsed| try std.testing.expectEqualStrings("refs", parsed.value.name),
    }

    const with_args = try api.operations.getWithArgs.send(bg, std.testing.allocator, .{
        .query = .{
            .optional_argument = null,
            .required_argument = 7,
        },
        .header = .{
            .header_argument = 11,
        },
    });
    defer api.operations.getWithArgs.deinitResponse(with_args);
    switch (with_args.value) {
        .status_200 => |parsed| try std.testing.expectEqualStrings("args", parsed.value.name),
    }

    const created = try api.operations.createResource2.send(bg, std.testing.allocator, .{
        .path = .{
            .inline_argument = 9,
        },
        .query = .{
            .inline_query_argument = 3,
        },
        .body = ClientApi.models.Resource{
            .name = "demo",
            .value = 1.5,
        },
    });
    defer api.operations.createResource2.deinitResponse(created);
    switch (created.value) {
        .status_200 => |parsed| try std.testing.expectEqualStrings("created", parsed.value.name),
    }

    try std.testing.expectEqual(@as(usize, 4), ctx.call_count);
}

pub fn TestRunner(comptime phase: Phase) testing.TestRunner {
    return switch (phase) {
        .spec => specRunner(),
        .typed_requests => testing.TestRunner.fromFn(std, 1024 * 1024, run_generated_client_sends_typed_requests),
    };
}
