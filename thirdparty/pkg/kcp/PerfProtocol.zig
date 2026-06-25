const glib = @import("glib");

const PerfProtocol = @This();

pub const magic = "NP1";
pub const default_bytes: usize = 5 * 1024 * 1024;
pub const default_udp_payload: usize = 1400;
pub const default_udp_pps: u32 = 1650;
pub const default_stream_chunk: usize = 8192;
pub const default_control_port: u16 = 9821;
pub const default_conv: u32 = 0x4b435031;
pub const max_line_len: usize = 768;

pub const Protocol = enum {
    tcp,
    udp,
    ikcp_packet,
    ikcp_stream,

    pub fn parse(value: []const u8) !Protocol {
        if (glib.std.mem.eql(u8, value, "tcp")) return .tcp;
        if (glib.std.mem.eql(u8, value, "udp")) return .udp;
        if (glib.std.mem.eql(u8, value, "ikcp-packet") or
            glib.std.mem.eql(u8, value, "ikcp_packet")) return .ikcp_packet;
        if (glib.std.mem.eql(u8, value, "ikcp-stream") or
            glib.std.mem.eql(u8, value, "ikcp_stream") or
            glib.std.mem.eql(u8, value, "kcp")) return .ikcp_stream;
        return error.InvalidProtocol;
    }

    pub fn name(self: Protocol) []const u8 {
        return switch (self) {
            .tcp => "tcp",
            .udp => "udp",
            .ikcp_packet => "ikcp-packet",
            .ikcp_stream => "ikcp-stream",
        };
    }

    pub fn isIkcp(self: Protocol) bool {
        return self == .ikcp_packet or self == .ikcp_stream;
    }
};

pub const Direction = enum {
    down,
    up,
    duplex,
    ping,

    pub fn parse(value: []const u8) !Direction {
        if (glib.std.mem.eql(u8, value, "down")) return .down;
        if (glib.std.mem.eql(u8, value, "up")) return .up;
        if (glib.std.mem.eql(u8, value, "duplex")) return .duplex;
        if (glib.std.mem.eql(u8, value, "ping")) return .ping;
        return error.InvalidDirection;
    }
};

pub const KcpConfig = struct {
    send_window: u32 = 32,
    recv_window: u32 = 32,
    nodelay: i32 = 1,
    interval_ms: i32 = 10,
    resend: i32 = 2,
    no_congestion_control: i32 = 1,
    stream: bool = true,
};

pub const Request = struct {
    protocol: Protocol = .ikcp_stream,
    direction: Direction = .down,
    bytes: usize = default_bytes,
    conv: u32 = default_conv,
    udp_pps: u32 = default_udp_pps,
    kcp: KcpConfig = .{},

    pub fn streamChunk(_: Request) usize {
        return default_stream_chunk;
    }

    pub fn udpPayload(_: Request) usize {
        return default_udp_payload;
    }

    pub fn nodelayEnabled(self: Request) bool {
        return self.kcp.nodelay != 0;
    }
};

pub const Ready = struct {
    tcp_port: u16 = 0,
    udp_port: u16 = 0,
    conv: u32 = default_conv,
};

pub const Result = struct {
    sent_bytes: usize = 0,
    received_bytes: usize = 0,
    elapsed_ns: u64 = 0,
    errors: u32 = 0,
    packets: u32 = 0,
    first_byte_ns: u64 = 0,
    rtt_ns: u64 = 0,

    pub fn mbps(self: Result) f64 {
        if (self.elapsed_ns == 0) return 0;
        return (@as(f64, @floatFromInt(self.received_bytes)) * 8.0 * 1000.0) /
            @as(f64, @floatFromInt(self.elapsed_ns));
    }
};

pub fn requestLine(comptime std: type, out: []u8, req: Request) ![]u8 {
    return std.fmt.bufPrint(
        out,
        "{s} REQ {s} {s} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n",
        .{
            magic,
            req.protocol.name(),
            @tagName(req.direction),
            req.bytes,
            req.conv,
            req.udp_pps,
            req.kcp.send_window,
            req.kcp.recv_window,
            req.kcp.nodelay,
            req.kcp.interval_ms,
            req.kcp.resend,
            req.kcp.no_congestion_control,
            @intFromBool(req.protocol == .ikcp_stream),
        },
    );
}

pub fn readyLine(comptime std: type, out: []u8, ready: Ready) ![]u8 {
    return std.fmt.bufPrint(out, "{s} READY {d} {d} {d}\n", .{
        magic,
        ready.tcp_port,
        ready.udp_port,
        ready.conv,
    });
}

pub fn resultLine(comptime std: type, out: []u8, role: []const u8, result: Result) ![]u8 {
    return std.fmt.bufPrint(out, "{s} RESULT {s} {d} {d} {d} {d} {d} {d} {d}\n", .{
        magic,
        role,
        result.sent_bytes,
        result.received_bytes,
        result.elapsed_ns,
        result.errors,
        result.packets,
        result.first_byte_ns,
        result.rtt_ns,
    });
}

pub fn stopLine(comptime std: type, out: []u8, result: Result) ![]u8 {
    return std.fmt.bufPrint(out, "{s} STOP {d} {d} {d} {d} {d} {d} {d}\n", .{
        magic,
        result.sent_bytes,
        result.received_bytes,
        result.elapsed_ns,
        result.errors,
        result.packets,
        result.first_byte_ns,
        result.rtt_ns,
    });
}

pub fn helloLine(comptime std: type, out: []u8, conv: u32) ![]u8 {
    return std.fmt.bufPrint(out, "{s} HELLO {d}\n", .{ magic, conv });
}

pub fn isDiagLine(comptime std: type, line: []const u8) bool {
    const trimmed = trimLine(std, line);
    return std.mem.startsWith(u8, trimmed, magic ++ " DIAG ");
}

pub fn parseRequest(comptime std: type, line: []const u8) !Request {
    var it = std.mem.tokenizeScalar(u8, trimLine(std, line), ' ');
    try expectToken(it.next(), magic);
    try expectToken(it.next(), "REQ");

    var req = Request{};
    req.protocol = try Protocol.parse(it.next() orelse return error.InvalidRequest);
    req.direction = try Direction.parse(it.next() orelse return error.InvalidRequest);
    req.bytes = try parseInt(std, usize, it.next());
    req.conv = try parseInt(std, u32, it.next());
    req.udp_pps = try parseInt(std, u32, it.next());
    req.kcp.send_window = try parseInt(std, u32, it.next());
    req.kcp.recv_window = try parseInt(std, u32, it.next());
    req.kcp.nodelay = try parseInt(std, i32, it.next());
    req.kcp.interval_ms = try parseInt(std, i32, it.next());
    req.kcp.resend = try parseInt(std, i32, it.next());
    req.kcp.no_congestion_control = try parseInt(std, i32, it.next());
    req.kcp.stream = (try parseInt(std, u8, it.next())) != 0;
    if (it.next() != null) return error.InvalidRequest;
    return req;
}

pub fn parseReady(comptime std: type, line: []const u8) !Ready {
    var it = std.mem.tokenizeScalar(u8, trimLine(std, line), ' ');
    try expectToken(it.next(), magic);
    try expectToken(it.next(), "READY");
    const ready = Ready{
        .tcp_port = try parseInt(std, u16, it.next()),
        .udp_port = try parseInt(std, u16, it.next()),
        .conv = try parseInt(std, u32, it.next()),
    };
    if (it.next() != null) return error.InvalidReady;
    return ready;
}

pub fn parseResult(comptime std: type, line: []const u8) !Result {
    var it = std.mem.tokenizeScalar(u8, trimLine(std, line), ' ');
    try expectToken(it.next(), magic);
    try expectToken(it.next(), "RESULT");
    _ = it.next() orelse return error.InvalidResult;
    const result = Result{
        .sent_bytes = try parseInt(std, usize, it.next()),
        .received_bytes = try parseInt(std, usize, it.next()),
        .elapsed_ns = try parseInt(std, u64, it.next()),
        .errors = try parseInt(std, u32, it.next()),
        .packets = try parseInt(std, u32, it.next()),
    };
    var mutable = result;
    if (it.next()) |value| {
        mutable.first_byte_ns = try parseInt(std, u64, value);
        mutable.rtt_ns = try parseInt(std, u64, it.next());
    }
    if (it.next() != null) return error.InvalidResult;
    return mutable;
}

pub fn parseStop(comptime std: type, line: []const u8) !Result {
    var it = std.mem.tokenizeScalar(u8, trimLine(std, line), ' ');
    try expectToken(it.next(), magic);
    try expectToken(it.next(), "STOP");
    const result = Result{
        .sent_bytes = try parseInt(std, usize, it.next()),
        .received_bytes = try parseInt(std, usize, it.next()),
        .elapsed_ns = try parseInt(std, u64, it.next()),
        .errors = try parseInt(std, u32, it.next()),
        .packets = try parseInt(std, u32, it.next()),
    };
    var mutable = result;
    if (it.next()) |value| {
        mutable.first_byte_ns = try parseInt(std, u64, value);
        mutable.rtt_ns = try parseInt(std, u64, it.next());
    }
    if (it.next() != null) return error.InvalidStop;
    return mutable;
}

pub fn trimLine(comptime std: type, line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r\n");
}

fn expectToken(found: ?[]const u8, expected: []const u8) !void {
    if (found == null) return error.InvalidLine;
    if (!glib.std.mem.eql(u8, found.?, expected)) return error.InvalidLine;
}

fn parseInt(comptime std: type, comptime T: type, value: ?[]const u8) !T {
    return std.fmt.parseInt(T, value orelse return error.InvalidLine, 10) catch error.InvalidLine;
}

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(std, 256 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: std.mem.Allocator) !void {
            _ = allocator;
            var buf: [max_line_len]u8 = undefined;
            try std.testing.expectEqual(Protocol.ikcp_packet, try Protocol.parse("ikcp-packet"));
            try std.testing.expectEqual(Protocol.ikcp_packet, try Protocol.parse("ikcp_packet"));
            try std.testing.expectEqual(Protocol.ikcp_stream, try Protocol.parse("ikcp-stream"));
            try std.testing.expectEqual(Protocol.ikcp_stream, try Protocol.parse("ikcp_stream"));
            try std.testing.expectEqual(Protocol.ikcp_stream, try Protocol.parse("kcp"));
            try std.testing.expectEqualStrings("ikcp-packet", Protocol.ikcp_packet.name());
            try std.testing.expectEqualStrings("ikcp-stream", Protocol.ikcp_stream.name());
            try std.testing.expect(Protocol.ikcp_packet.isIkcp());
            try std.testing.expect(Protocol.ikcp_stream.isIkcp());
            try std.testing.expect(!Protocol.tcp.isIkcp());
            try std.testing.expect(!Protocol.udp.isIkcp());

            const packet_req = Request{ .protocol = .ikcp_packet };
            const packet_line = try requestLine(std, &buf, packet_req);
            const parsed_packet = try parseRequest(std, packet_line);
            try std.testing.expectEqual(Protocol.ikcp_packet, parsed_packet.protocol);
            try std.testing.expect(!parsed_packet.kcp.stream);

            const req = Request{
                .protocol = .ikcp_stream,
                .direction = .duplex,
                .bytes = 4096,
                .conv = 9,
                .kcp = .{
                    .send_window = 64,
                    .recv_window = 32,
                    .no_congestion_control = 0,
                },
            };
            const line = try requestLine(std, &buf, req);
            const parsed = try parseRequest(std, line);
            try std.testing.expectEqual(req.protocol, parsed.protocol);
            try std.testing.expectEqual(req.direction, parsed.direction);
            try std.testing.expectEqual(req.bytes, parsed.bytes);
            try std.testing.expectEqual(req.udp_pps, parsed.udp_pps);
            try std.testing.expectEqual(req.kcp.send_window, parsed.kcp.send_window);
            try std.testing.expectEqual(@as(usize, 8192), parsed.streamChunk());
            try std.testing.expectEqual(@as(usize, 1400), parsed.udpPayload());

            const invalid_line = try std.fmt.bufPrint(
                &buf,
                "{s} REQ kcp down 4096 1250 1650 9 64 32 1 10 2 1 1 1\n",
                .{magic},
            );
            try std.testing.expectError(error.InvalidRequest, parseRequest(std, invalid_line));

            const stop_line = try stopLine(std, &buf, .{
                .sent_bytes = 1,
                .received_bytes = 2,
                .elapsed_ns = 3,
                .errors = 4,
                .packets = 5,
            });
            const stopped = try parseStop(std, stop_line);
            try std.testing.expectEqual(@as(usize, 1), stopped.sent_bytes);
            try std.testing.expectEqual(@as(usize, 2), stopped.received_bytes);
            try std.testing.expectEqual(@as(u64, 3), stopped.elapsed_ns);
            try std.testing.expectEqual(@as(u32, 4), stopped.errors);
            try std.testing.expectEqual(@as(u32, 5), stopped.packets);
        }
    }.run);
}
