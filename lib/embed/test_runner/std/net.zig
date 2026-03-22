pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.net);

    try ip4AddressTests(lib);
    try ip6AddressTests(lib);
    try addressTests(lib);

    log.info("net defs done", .{});
}

fn ip4AddressTests(comptime lib: type) !void {
    const log = lib.log.scoped(.net);

    var addr = lib.net.Ip4Address.init(.{ 10, 0, 1, 2 }, 8080);
    if (addr.getPort() != 8080) return error.Ip4PortMismatch;
    log.info("Ip4Address.init port={}", .{addr.getPort()});

    addr.setPort(9090);
    if (addr.getPort() != 9090) return error.Ip4SetPortFailed;

    const parsed = try lib.net.Ip4Address.parse("127.0.0.1", 443);
    if (parsed.getPort() != 443) return error.Ip4ParsePortMismatch;

    if (lib.net.Ip4Address.parse("127.0.0", 80)) |_|
        return error.Ip4ParseShouldFail
    else |_| {}

    log.info("Ip4Address: init+setPort+parse ok", .{});
}

fn ip6AddressTests(comptime lib: type) !void {
    const log = lib.log.scoped(.net);

    var addr = lib.net.Ip6Address.init(.{0} ** 16, 8080, 1, 2);
    if (addr.getPort() != 8080) return error.Ip6PortMismatch;
    if (addr.sa.flowinfo != 1) return error.Ip6FlowinfoMismatch;
    if (addr.sa.scope_id != 2) return error.Ip6ScopeIdMismatch;

    addr.setPort(9090);
    if (addr.getPort() != 9090) return error.Ip6SetPortFailed;

    const parsed = try lib.net.Ip6Address.parse("::1", 443);
    if (parsed.getPort() != 443) return error.Ip6ParsePortMismatch;

    const scoped = try lib.net.Ip6Address.parse("fe80::1%7", 80);
    if (scoped.sa.scope_id != 7) return error.Ip6ScopeParseMismatch;

    log.info("Ip6Address: init+setPort+parse ok", .{});
}

fn addressTests(comptime lib: type) !void {
    const log = lib.log.scoped(.net);

    var a4 = lib.net.Address.initIp4(.{ 192, 168, 1, 9 }, 1234);
    if (a4.getPort() != 1234) return error.AddressIp4PortMismatch;
    if (a4.getOsSockLen() != @sizeOf(lib.posix.sockaddr.in)) return error.AddressIp4SockLenMismatch;
    a4.setPort(4321);
    if (a4.getPort() != 4321) return error.AddressIp4SetPortFailed;

    const parsed4 = try lib.net.Address.parseIp("10.1.2.3", 53);
    if (parsed4.getPort() != 53) return error.AddressParseIp4Failed;

    const parsed6 = try lib.net.Address.parseIp6("2001:db8::1", 853);
    if (parsed6.getPort() != 853) return error.AddressParseIp6Failed;
    if (parsed6.getOsSockLen() != @sizeOf(lib.posix.sockaddr.in6)) return error.AddressIp6SockLenMismatch;

    if (lib.net.Address.parseIp("not-an-ip", 80)) |_|
        return error.AddressParseShouldFail
    else |_| {}

    log.info("Address: init+parse+setPort+socklen ok", .{});
}
