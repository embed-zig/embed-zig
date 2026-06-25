pub fn register(registry: anytype) void {
    const embed = registry.b.dependency("embed", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("embed");
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");
    const kcp = registry.thirdpartyModule("kcp");

    const options = registry.b.addOptions();
    options.addOption(bool, "wifi_connect", registry.b.option(bool, "netperf_wifi_connect", "Connect WiFi before running netperf") orelse false);
    options.addOption([]const u8, "wifi_ssid", registry.b.option([]const u8, "netperf_wifi_ssid", "WiFi SSID for ESP netperf") orelse "");
    options.addOption([]const u8, "wifi_password", registry.b.option([]const u8, "netperf_wifi_password", "WiFi password for ESP netperf") orelse "");
    options.addOption([]const u8, "host", registry.b.option([]const u8, "netperf_host", "Netperf control host IP") orelse "127.0.0.1");
    options.addOption(u16, "port", registry.b.option(u16, "netperf_port", "Netperf control TCP port") orelse 9821);
    options.addOption([]const u8, "protocol", registry.b.option([]const u8, "netperf_protocol", "tcp, udp, ikcp-packet, ikcp-stream, ikcp-memory, or all") orelse "all");
    options.addOption([]const u8, "direction", registry.b.option([]const u8, "netperf_direction", "up, down, duplex, ping, or all") orelse "all");
    options.addOption(usize, "bytes", registry.b.option(usize, "netperf_bytes", "Bytes per direction") orelse 5 * 1024 * 1024);
    options.addOption(u32, "udp_pps", registry.b.option(u32, "netperf_udp_pps", "Raw UDP send packets per second, 0 disables pacing") orelse 1650);
    options.addOption(u32, "send_window", registry.b.option(u32, "netperf_kcp_snd_wnd", "KCP send window") orelse 32);
    options.addOption(u32, "recv_window", registry.b.option(u32, "netperf_kcp_rcv_wnd", "KCP receive window") orelse 32);
    options.addOption(i32, "nodelay", registry.b.option(i32, "netperf_nodelay", "TCP_NODELAY / KCP nodelay value") orelse 1);
    options.addOption(i32, "interval_ms", registry.b.option(i32, "netperf_kcp_interval_ms", "KCP update interval in milliseconds") orelse 10);
    options.addOption(i32, "resend", registry.b.option(i32, "netperf_kcp_resend", "KCP fast resend value") orelse 2);
    options.addOption(i32, "no_congestion_control", registry.b.option(i32, "netperf_kcp_nc", "KCP nc value") orelse 1);

    const mod = registry.b.addModule("zux_netperf", .{
        .root_source_file = registry.b.path("zux/netperf/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "kcp", .module = kcp },
            .{ .name = "launcher", .module = registry.launcher },
        },
    });
    mod.addOptions("netperf_app_config", options);
    registry.add("zux_netperf", mod);
}
