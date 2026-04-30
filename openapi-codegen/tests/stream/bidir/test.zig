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

fn runStreamBidirTest(t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    var app = AppContext{};

    var server = try ServerApi.init(alloc, &app, .{
        .streamBidir = Handlers.streamBidir,
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

    const bidir_in = "echo-me";
    var bidir_body = FixedBufferBody{ .bytes = bidir_in };
    const resp = try api.operations.streamBidir.send(t.context(), alloc, .{
        .body = net.http.ReadCloser.init(&bidir_body),
    });
    defer resp.deinit();

    switch (resp.value) {
        .status_200 => |reader| {
            defer reader.close();
            var buf: [64]u8 = undefined;
            var len: usize = 0;
            while (len < buf.len) {
                const n = try reader.read(buf[len..]);
                if (n == 0) break;
                len += n;
            }
            if (!lib.mem.eql(u8, buf[0..len], bidir_in)) return error.BidirMismatch;
        },
    }
}

const AppContext = struct {};

const Handlers = struct {
    fn streamBidir(
        ptr: *anyopaque,
        ctx: context.Context,
        allocator: lib.mem.Allocator,
        args: ServerApi.operations.streamBidir.Args,
    ) !ServerApi.operations.streamBidir.Response {
        _ = ptr;
        _ = ctx;
        const reader = args.body;
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
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, runStreamBidirTest);
}
