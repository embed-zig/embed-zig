pub const meta = .{
    .source_file = sourceFile(),
    .module = "embed/bt",
    .filter = "embed/bt/unit/kcp/gstd",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");
const kcp = @import("kcp");

const BtKcp = embed.bt.kcp.make(gstd.runtime, kcp);

const Link = struct {
    peer: ?*BtKcp.Stream = null,

    fn output(ctx: ?*anyopaque, data: []const u8) anyerror!void {
        const self: *Link = @ptrCast(@alignCast(ctx.?));
        const peer = self.peer orelse return error.NoPeer;
        try peer.input(data);
    }
};

test "embed/bt/unit/kcp/gstd stream transfers payloads over packet output" {
    const allocator = gstd.runtime.std.testing.allocator;
    var left_link = Link{};
    var right_link = Link{};

    var left = try BtKcp.makeStream(allocator, .{
        .tx_char_uuid = 0xFEE1,
        .rx_char_uuid = 0xFEE2,
        .att_mtu = 128,
    }, &left_link, Link.output);
    defer left.deinit();

    var right = try BtKcp.makeStream(allocator, .{
        .tx_char_uuid = 0xFEE1,
        .rx_char_uuid = 0xFEE2,
        .att_mtu = 128,
    }, &right_link, Link.output);
    defer right.deinit();

    left_link.peer = right;
    right_link.peer = left;

    try left.write("hello over kcp");

    var buf: [64]u8 = undefined;
    const n = (try right.readTimeout(buf[0..], 2 * glib.time.duration.Second)) orelse return error.Timeout;
    try gstd.runtime.std.testing.expectEqualStrings("hello over kcp", buf[0..n]);
}

test "embed/bt/unit/kcp/gstd stream reads preserve payload across small buffers" {
    const allocator = gstd.runtime.std.testing.allocator;
    var left_link = Link{};
    var right_link = Link{};

    var left = try BtKcp.makeStream(allocator, .{
        .tx_char_uuid = 0xFEE1,
        .rx_char_uuid = 0xFEE2,
        .att_mtu = 128,
    }, &left_link, Link.output);
    defer left.deinit();

    var right = try BtKcp.makeStream(allocator, .{
        .tx_char_uuid = 0xFEE1,
        .rx_char_uuid = 0xFEE2,
        .att_mtu = 128,
    }, &right_link, Link.output);
    defer right.deinit();

    left_link.peer = right;
    right_link.peer = left;

    try left.write("hello over kcp");

    var first: [5]u8 = undefined;
    var second: [5]u8 = undefined;
    var third: [8]u8 = undefined;
    const first_n = (try right.readTimeout(first[0..], 2 * glib.time.duration.Second)) orelse return error.Timeout;
    const second_n = (try right.readTimeout(second[0..], 2 * glib.time.duration.Second)) orelse return error.Timeout;
    const third_n = (try right.readTimeout(third[0..], 2 * glib.time.duration.Second)) orelse return error.Timeout;

    try gstd.runtime.std.testing.expectEqualStrings("hello", first[0..first_n]);
    try gstd.runtime.std.testing.expectEqualStrings(" over", second[0..second_n]);
    try gstd.runtime.std.testing.expectEqualStrings(" kcp", third[0..third_n]);
}

test "embed/bt/unit/kcp/gstd client and server facade APIs instantiate" {
    const allocator = gstd.runtime.std.testing.allocator;

    var endpoint = try BtKcp.server.Endpoint.init(allocator, .{
        .tx_char_uuid = 0xFEE1,
        .rx_char_uuid = 0xFEE2,
        .handler = .{ .onStream = onServerStream },
    });
    defer endpoint.deinit();
    var fake_server = FakeServer{};
    try endpoint.handle(&fake_server);

    var fake_client = FakeClient{};
    var stream = try BtKcp.client.openStream(allocator, &fake_client, 1, .{
        .tx_char_uuid = 0xFEE1,
        .rx_char_uuid = 0xFEE2,
        .att_mtu = 64,
    });
    defer stream.deinit();
}

test "embed/bt/unit/kcp/gstd endpoint reports handler errors" {
    const allocator = gstd.runtime.std.testing.allocator;

    var endpoint = try BtKcp.server.Endpoint.init(allocator, .{
        .tx_char_uuid = 0xFEE1,
        .rx_char_uuid = 0xFEE2,
        .handler = .{ .onStream = onFailingServerStream },
    });
    defer endpoint.deinit();

    var fake_server = FakeServer{ .auto_subscribe = true };
    try endpoint.handle(&fake_server);

    try gstd.runtime.std.testing.expectError(error.HandlerFailed, endpoint.run());
}

test "embed/bt/unit/kcp/gstd rejects ATT MTU that cannot carry KCP segments" {
    const allocator = gstd.runtime.std.testing.allocator;
    var link = Link{};

    const result = BtKcp.makeStream(allocator, .{
        .tx_char_uuid = 0xFEE1,
        .rx_char_uuid = 0xFEE2,
        .att_mtu = 23,
    }, &link, Link.output);
    try gstd.runtime.std.testing.expectError(error.InvalidMtu, result);
}

fn onServerStream(ctx: ?*anyopaque, stream: *BtKcp.Stream) anyerror!void {
    _ = ctx;
    _ = stream;
}

fn onFailingServerStream(ctx: ?*anyopaque, stream: *BtKcp.Stream) anyerror!void {
    _ = ctx;
    defer stream.deinit();
    return error.HandlerFailed;
}

const FakeClient = struct {
    pub fn resolveCharacteristic(self: *FakeClient, conn_handle: u16, service_uuid: u16, char_uuid: u16) !FakeChar {
        _ = self;
        _ = conn_handle;
        _ = service_uuid;
        return .{ .uuid = char_uuid };
    }
};

const FakeChar = struct {
    uuid: u16,

    pub fn subscribe(self: *FakeChar) !FakeSubscription {
        _ = self;
        return .{};
    }

    pub fn writeNoResp(self: *FakeChar, data: []const u8) !void {
        _ = self;
        _ = data;
    }
};

const FakeSubscription = struct {
    pub fn deinit(self: *FakeSubscription) void {
        _ = self;
    }

    pub fn attMtu(self: *const FakeSubscription) u16 {
        _ = self;
        return 64;
    }

    pub fn write(self: *FakeSubscription, data: []const u8) !void {
        _ = self;
        _ = data;
    }

    pub fn next(self: *FakeSubscription, timeout: glib.time.duration.Duration) !?FakeMessage {
        _ = self;
        gstd.runtime.time.sleep(timeout);
        return null;
    }
};

const FakeMessage = struct {
    pub fn payload(self: FakeMessage) []const u8 {
        _ = self;
        return "";
    }
};

const FakeServer = struct {
    pub const Subscription = FakeSubscription;

    auto_subscribe: bool = false,

    pub fn handle(self: *FakeServer, service_uuid: u16, char_uuid: u16, handler: anytype, ctx: ?*anyopaque) !void {
        _ = service_uuid;
        _ = char_uuid;
        if (@hasField(@TypeOf(handler), "onSubscription")) {
            const callback: *const fn (?*anyopaque, FakeSubscription) void = handler.onSubscription;
            if (self.auto_subscribe) callback(ctx, .{});
        }
        if (@hasField(@TypeOf(handler), "onRequest")) {
            const bt = embed.bt;
            const callback: *const fn (?*anyopaque, *const bt.Peripheral.Request, *bt.Peripheral.ResponseWriter) void = handler.onRequest;
            _ = callback;
        }
    }
};
