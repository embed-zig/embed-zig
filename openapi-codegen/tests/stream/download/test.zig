const context = embed.context;
const testing_api = embed.testing;
const net_mod = embed.net;
const openapi = @import("openapi");
const codegen = @import("codegen");

const embed = @import("embed");
const lib = @import("embed_std").std;
const net = embed.net.make(lib);

const raw_spec = @embedFile("spec.json");
pub const download_len: usize = 8192;

fn files() openapi.Files {
    const spec = openapi.json.parse(raw_spec);
    return .{
        .items = &.{.{ .name = "spec.json", .spec = spec }},
    };
}

const ClientApi = codegen.client.make(lib, files());
const ServerApi = codegen.server.make(lib, files());

fn runStreamDownloadTest(t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    var app = AppContext{};
    app.initDownloadPattern();

    var server = try ServerApi.init(alloc, &app, .{
        .streamDownload = Handlers.streamDownload,
    });
    defer server.deinit();

    var srv_run = try startServer(&server);
    defer srv_run.stop(&server) catch {};

    const base_url = try lib.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{srv_run.port});
    defer alloc.free(base_url);

    var transport = try net.http.Transport.init(alloc, .{});
    defer transport.deinit();
    var http_client = try net.http.Client.init(alloc, .{
        .round_tripper = transport.roundTripper(),
    });
    defer http_client.deinit();

    var api = try ClientApi.init(.{
        .allocator = alloc,
        .http_client = &http_client,
        .base_url = base_url,
    });
    defer api.deinit();

    const resp = try api.operations.streamDownload.send(t.context(), alloc, .{});
    defer resp.deinit();

    switch (resp.value) {
        .status_200 => |reader| {
            defer reader.close();
            var buf: [512]u8 = undefined;
            var total: usize = 0;
            var expect_off: usize = 0;
            while (true) {
                const n = try reader.read(&buf);
                if (n == 0) break;
                for (buf[0..n], 0..) |byte, j| {
                    const exp: u8 = @truncate(expect_off + j);
                    if (byte != exp) return error.StreamDownloadMismatch;
                }
                expect_off += n;
                total += n;
                if (total > download_len) return error.StreamDownloadTooLong;
            }
            if (total != download_len) return error.StreamDownloadShort;
        },
    }
}

const AppContext = struct {
    download_body: [download_len]u8 = undefined,

    fn initDownloadPattern(self: *@This()) void {
        for (&self.download_body, 0..) |*b, i| {
            b.* = @truncate(i);
        }
    }
};

const Handlers = struct {
    fn streamDownload(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: lib.mem.Allocator,
        args: ServerApi.operations.streamDownload.Args,
    ) !ServerApi.operations.streamDownload.Response {
        const app: *AppContext = @ptrCast(@alignCast(ptr));
        _ = ctx;
        _ = allocator;
        _ = args;
        return .{ .status_200 = &app.download_body };
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
    const listener = try net.listen(server.shared.allocator, .{
        .address = net_mod.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 0),
    });
    const tcp_listener = try listener.as(net.TcpListener);
    const port = try tcp_listener.port();

    var srv_run = ServerRun{
        .listener = listener,
        .port = port,
        .thread = undefined,
    };
    srv_run.thread = try lib.Thread.spawn(.{}, struct {
        fn exec(s: *ServerApi, ln: net_mod.Listener, err: *?anyerror) void {
            s.serve(ln) catch |serve_err| {
                err.* = serve_err;
            };
        }
    }.exec, .{ server, listener, &srv_run.server_err });
    return srv_run;
}

pub fn TestRunner() testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, runStreamDownloadTest);
}
