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
    const protocol_text = args.next() orelse "kcp";
    const direction_text = args.next() orelse "down";
    const bytes = try parseArg(usize, args.next(), 10 * 1024 * 1024);
    const udp_pps = try parseArg(u32, args.next(), 1250);
    const snd_wnd = try parseArg(u32, args.next(), 32);
    const rcv_wnd = try parseArg(u32, args.next(), 32);
    const nodelay = try parseArg(i32, args.next(), 1);
    const interval_ms = try parseArg(i32, args.next(), 10);
    const resend = try parseArg(i32, args.next(), 2);
    const nc = try parseArg(i32, args.next(), 1);

    const Protocol = kcp.PerfProtocol;
    const request = Protocol.Request{
        .protocol = try Protocol.Protocol.parse(protocol_text),
        .direction = try Protocol.Direction.parse(direction_text),
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
    const result = try client.run(addr, request);

    std.debug.print(
        "netperf client={s} server={s}:{d} protocol={s} direction={s} bytes={d} stream_chunk={d} udp_payload={d} udp_pps={d} wnd={d}/{d} nodelay={d} interval={d} resend={d} nc={d}\n",
        .{
            "host",
            host,
            port,
            protocol_text,
            direction_text,
            bytes,
            request.streamChunk(),
            request.udpPayload(),
            udp_pps,
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
