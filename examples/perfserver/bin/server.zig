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

    const host = args.next() orelse "0.0.0.0";
    const port_text = args.next() orelse "9821";
    const port = try std.fmt.parseInt(u16, port_text, 10);
    const addr = glib.net.netip.AddrPort.init(try glib.net.netip.Addr.parse(host), port);

    const Server = kcp.NetperfServer(gstd.runtime);
    var server = Server.init(allocator, .{
        .control_addr = addr,
    });

    std.log.info("netperf-server listening on {s}:{d}", .{ host, port });
    try server.serve();
}
