const context = embed.context;
const testing_api = embed.testing;
const net_mod = embed.net;
const openapi = @import("openapi");
const codegen = @import("codegen");

const embed = @import("embed");
const lib = @import("embed_std").std;
const net = embed.net.make(lib);

const raw_spec = @embedFile("spec.json");

fn files() openapi.Files {
    const spec = openapi.json.parse(raw_spec);
    return .{
        .items = &.{.{ .name = "spec.json", .spec = spec }},
    };
}

const ClientApi = codegen.client.make(lib, files());
const ServerApi = codegen.server.make(lib, files());

const ChunkedPartsBody = struct {
    parts: []const []const u8,
    part: usize = 0,
    off: usize = 0,

    pub fn read(self: *@This(), buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            if (self.part >= self.parts.len) return total;
            const cur = self.parts[self.part][self.off..];
            if (cur.len == 0) {
                self.part += 1;
                self.off = 0;
                continue;
            }
            const need = buf.len - total;
            const take = @min(need, cur.len);
            @memcpy(buf[total..][0..take], cur[0..take]);
            total += take;
            self.off += take;
            if (self.off >= self.parts[self.part].len) {
                self.part += 1;
                self.off = 0;
            }
        }
        return total;
    }

    pub fn close(_: *@This()) void {}
};

fn runStreamUploadTest(t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    var app = AppContext{};

    var server = try ServerApi.init(alloc, &app, .{
        .streamUpload = Handlers.streamUpload,
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

    const expected = "hello-upload";
    var chunked = ChunkedPartsBody{ .parts = &.{ "hello-", "upload" } };
    const resp = try api.operations.streamUpload.send(t.context(), alloc, .{
        .body = net.http.ReadCloser.init(&chunked),
    });
    defer resp.deinit();

    switch (resp.value) {
        .status_204 => {},
    }
    if (!lib.mem.eql(u8, app.last_upload, expected)) return error.UploadNotSeen;
}

const AppContext = struct {
    upload_scratch: [256]u8 = undefined,
    last_upload: []const u8 = "",
};

const Handlers = struct {
    fn streamUpload(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: lib.mem.Allocator,
        args: ServerApi.operations.streamUpload.Args,
    ) !ServerApi.operations.streamUpload.Response {
        const app: *AppContext = @ptrCast(@alignCast(ptr));
        _ = ctx;
        _ = allocator;
        const reader = args.body;
        defer reader.close();
        var len: usize = 0;
        while (len < app.upload_scratch.len) {
            const n = try reader.read(app.upload_scratch[len..]);
            if (n == 0) break;
            len += n;
        }
        app.last_upload = app.upload_scratch[0..len];
        return .{ .status_204 = {} };
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
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, runStreamUploadTest);
}
