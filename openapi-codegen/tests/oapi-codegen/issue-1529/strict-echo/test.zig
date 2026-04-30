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
            .{ .name = "spec.json", .spec = spec },
        },
    };
    break :blk codegen.client.make(lib, files);
};

const ServerApi = blk: {
    const spec = openapi.json.parse(@embedFile("spec.json"));
    const files: openapi.Files = .{
        .items = &.{
            .{ .name = "spec.json", .spec = spec },
        },
    };
    break :blk codegen.server.make(lib, files);
};

pub const Phase = enum {
    spec,
    strict_framework,
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
            try std.testing.expectEqualStrings("", spec.info.title);
            try std.testing.expectEqualStrings("", spec.info.version);
            try std.testing.expectEqual(@as(usize, 1), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/test") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("test", get_op.operation_id orelse return error.FixtureMismatch);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 1), components.schemas.len);
            const _sor_Test = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Test") orelse return error.FixtureMismatch;
            switch (_sor_Test) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
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
    fn test_(ctx_ptr: *anyopaque, req_ctx: Context, allocator: lib.mem.Allocator, args: ServerApi.operations.@"test".Args) !ServerApi.operations.@"test".Response {
        _ = req_ctx;
        _ = allocator;
        const ctx: *AppContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.call_count += 1;
        _ = args;
        return .{ .status_200 = .{} };
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

fn run_zig_semantic_equivalent_for_strict_framework_response_handli(t: *testing.T, allocator: std.mem.Allocator) !void {
    _ = t;
    _ = allocator;
    var ctx_ns = try embed.context.make(lib).init(std.testing.allocator);
    defer ctx_ns.deinit();
    const bg = ctx_ns.background();

    var ctx = AppContext{};
    var server = try ServerApi.init(std.testing.allocator, &ctx, .{
        .@"test" = Handlers.test_,
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

    const response = try api.operations.@"test".send(bg, std.testing.allocator, .{});
    defer api.operations.@"test".deinitResponse(response);

    _ = response.value.status_200;
    try std.testing.expectEqual(@as(usize, 1), ctx.call_count);
}

pub fn TestRunner(comptime phase: Phase) testing.TestRunner {
    return switch (phase) {
        .spec => specRunner(),
        .strict_framework => testing.TestRunner.fromFn(std, 1024 * 1024, run_zig_semantic_equivalent_for_strict_framework_response_handli),
    };
}
