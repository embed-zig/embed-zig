const std = @import("std");
const glib = @import("glib");
const gstd = @import("gstd");
const kcp = @import("kcp");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    const host = args.next() orelse "127.0.0.1";
    const port = try parseArg(u16, args.next(), 9821);
    const protocol_text = args.next() orelse "ikcp-stream";
    const direction_text = args.next() orelse "down";
    const bytes = try parseArg(usize, args.next(), 10 * 1024 * 1024);
    const snd_wnd = try parseArg(u32, args.next(), 32);
    const rcv_wnd = try parseArg(u32, args.next(), 32);
    const nodelay = try parseArg(i32, args.next(), 1);
    const interval_ms = try parseArg(i32, args.next(), 10);
    const resend = try parseArg(i32, args.next(), 2);
    const nc = try parseArg(i32, args.next(), 1);
    const udp_pps = try parseArg(u32, args.next(), kcp.PerfProtocol.default_udp_pps);

    const Protocol = kcp.PerfProtocol;
    const protocol = try Protocol.Protocol.parse(protocol_text);
    const direction = try Protocol.Direction.parse(direction_text);
    const request = Protocol.Request{
        .protocol = protocol,
        .direction = direction,
        .conv = uniqueConv(Protocol.default_conv, protocol, direction),
        .bytes = bytes,
        .udp_pps = udp_pps,
        .kcp = .{
            .send_window = snd_wnd,
            .recv_window = rcv_wnd,
            .nodelay = nodelay,
            .interval_ms = interval_ms,
            .resend = resend,
            .no_congestion_control = nc,
        },
    };
    const addr = glib.net.netip.AddrPort.init(try glib.net.netip.Addr.parse(host), port);

    const Client = kcp.NetperfClient(gstd.runtime);
    var client = Client.init(allocator);
    client.config.udp_socket_buffer_size = 4 * 1024 * 1024;
    const result = try client.run(addr, request);

    std.debug.print(
        "netperf client={s} server={s}:{d} protocol={s} direction={s} bytes={d} stream_chunk={d} udp_payload={d} udp_pps={d} wnd={d}/{d} nodelay={d} interval={d} resend={d} nc={d}\n",
        .{
            "host",
            host,
            port,
            request.protocol.name(),
            direction_text,
            bytes,
            request.streamChunk(),
            request.udpPayload(),
            request.udp_pps,
            snd_wnd,
            rcv_wnd,
            nodelay,
            interval_ms,
            resend,
            nc,
        },
    );
    printResult("client", result.client);
    printResult("server", result.server);
}

fn parseArg(comptime T: type, value: ?[]const u8, fallback: T) !T {
    return std.fmt.parseInt(T, value orelse return fallback, 10);
}

fn uniqueConv(base: u32, protocol: kcp.PerfProtocol.Protocol, direction: kcp.PerfProtocol.Direction) u32 {
    const now_ns: u64 = @intCast(std.time.nanoTimestamp());
    return base ^
        @as(u32, @truncate(now_ns)) ^
        (@as(u32, @intFromEnum(protocol)) << 16) ^
        (@as(u32, @intFromEnum(direction)) << 24);
}

fn printResult(role: []const u8, result: kcp.PerfProtocol.Result) void {
    std.debug.print(
        "{s}: sent={d} recv={d} elapsed_ns={d} mbps={d:.3} packets={d} errors={d} first_byte_ns={d} rtt_ns={d}\n",
        .{
            role,
            result.sent_bytes,
            result.received_bytes,
            result.elapsed_ns,
            result.mbps(),
            result.packets,
            result.errors,
            result.first_byte_ns,
            result.rtt_ns,
        },
    );
}
