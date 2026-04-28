//! Shared helpers for TLS integration cases under `tls/`.

const net_mod = @import("../../../../net.zig");
const tls_fixtures = @import("../../../../net/tls/test_fixtures.zig");
const tcp_test_utils = @import("../tcp/test_utils.zig");

pub fn readAll(conn: net_mod.Conn, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try conn.read(buf[filled..]);
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

pub fn writeAll(conn: net_mod.Conn, buf: []const u8) !void {
    var written: usize = 0;
    while (written < buf.len) {
        const n = try conn.write(buf[written..]);
        if (n == 0) return error.BrokenPipe;
        written += n;
    }
}

pub fn runLoopbackCase(
    comptime std: type,
    alloc: std.mem.Allocator,
    comptime NetType: type,
    min_version: NetType.tls.ProtocolVersion,
    max_version: NetType.tls.ProtocolVersion,
    expected_version: NetType.tls.ProtocolVersion,
    expected_suite: ?NetType.tls.CipherSuite,
    client_tls13_cipher_suites: ?[]const NetType.tls.CipherSuite,
    server_tls13_cipher_suites: ?[]const NetType.tls.CipherSuite,
) !void {
    const Thread = std.Thread;
    const test_spawn_config: Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 };

    var server_config: NetType.tls.ServerConfig = .{
        .certificates = &.{.{
            .chain = &.{tls_fixtures.self_signed_cert_der[0..]},
            .private_key = .{ .ecdsa_p256_sha256 = tls_fixtures.self_signed_key_scalar },
        }},
        .min_version = min_version,
        .max_version = max_version,
    };
    if (server_tls13_cipher_suites) |suites| {
        server_config.tls13_cipher_suites = suites;
    }

    var ln = try NetType.tls.listen(alloc, .{
        .address = tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
    }, server_config);
    defer ln.deinit();

    const tls_l = try ln.as(NetType.tls.Listener);
    const tcp_listener = try tls_l.inner.as(NetType.TcpListener);
    const port = try tcp_listener.port();

    var server_result: ?anyerror = null;
    var server_thread = try Thread.spawn(test_spawn_config, struct {
        fn run(
            listener: *NetType.tls.Listener,
            expected: NetType.tls.ProtocolVersion,
            suite: ?NetType.tls.CipherSuite,
            result: *?anyerror,
        ) void {
            var conn = listener.accept() catch |err| {
                result.* = err;
                return;
            };
            defer conn.deinit();

            const typed = conn.as(NetType.tls.ServerConn) catch {
                result.* = error.TestUnexpectedResult;
                return;
            };
            typed.handshake() catch |err| {
                result.* = err;
                return;
            };
            if (typed.handshake_state.version != expected) {
                result.* = error.TestUnexpectedResult;
                return;
            }
            if (suite) |wanted_suite| {
                if (typed.handshake_state.cipher_suite != wanted_suite) {
                    result.* = error.TestUnexpectedResult;
                    return;
                }
            }

            var buf: [4]u8 = undefined;
            readAll(conn, &buf) catch |err| {
                result.* = err;
                return;
            };
            writeAll(conn, "pong") catch |err| {
                result.* = err;
                return;
            };
            if (!std.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
        }
    }.run, .{ tls_l, expected_version, expected_suite, &server_result });
    defer server_thread.join();

    var client_config: NetType.tls.Config = .{
        .server_name = "example.com",
        .verification = .self_signed,
        .min_version = min_version,
        .max_version = max_version,
    };
    if (client_tls13_cipher_suites) |suites| {
        client_config.tls13_cipher_suites = suites;
    }

    var conn = try NetType.tls.dial(alloc, .tcp, tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, port), client_config);
    defer conn.deinit();

    const typed = try conn.as(NetType.tls.Conn);
    try typed.handshake();
    try std.testing.expectEqual(expected_version, typed.handshake_state.version);
    if (expected_suite) |suite| {
        try std.testing.expectEqual(suite, typed.handshake_state.cipher_suite);
    }

    try writeAll(conn, "ping");
    var resp: [4]u8 = undefined;
    try readAll(conn, &resp);
    try std.testing.expectEqualStrings("pong", &resp);
    if (server_result) |err| return err;
}

fn nextTrafficSecret(
    comptime NetType: type,
    suite: NetType.tls.CipherSuite,
    secret: [NetType.tls.MAX_TLS13_SECRET_LEN]u8,
) [NetType.tls.MAX_TLS13_SECRET_LEN]u8 {
    const profile = suite.tls13Profile() orelse unreachable;
    var next = [_]u8{0} ** NetType.tls.MAX_TLS13_SECRET_LEN;
    NetType.tls.hkdfExpandLabelIntoProfile(
        profile,
        next[0..profile.secretLength()],
        secret[0..profile.secretLength()],
        "traffic upd",
        "",
    );
    return next;
}

fn cipherFromTrafficSecret(
    comptime NetType: type,
    suite: NetType.tls.CipherSuite,
    traffic_secret: [NetType.tls.MAX_TLS13_SECRET_LEN]u8,
) !NetType.tls.CipherState() {
    const profile = suite.tls13Profile() orelse return error.TestUnexpectedResult;
    const key_len = suite.keyLength();
    if (key_len == 0 or key_len > 32) return error.TestUnexpectedResult;

    const secret = traffic_secret[0..profile.secretLength()];
    var iv: [12]u8 = undefined;
    NetType.tls.hkdfExpandLabelIntoProfile(profile, &iv, secret, "iv", "");
    var key = [_]u8{0} ** 32;
    switch (key_len) {
        16 => NetType.tls.hkdfExpandLabelIntoProfile(profile, key[0..16], secret, "key", ""),
        32 => NetType.tls.hkdfExpandLabelIntoProfile(profile, key[0..32], secret, "key", ""),
        else => return error.TestUnexpectedResult,
    }
    return try NetType.tls.CipherState().init(suite, key[0..key_len], &iv);
}

pub fn sendClientKeyUpdate(comptime NetType: type, client: *NetType.tls.Conn) !void {
    var msg: [NetType.tls.HandshakeHeader.SIZE + 1]u8 = undefined;
    const header: NetType.tls.HandshakeHeader = .{
        .msg_type = .key_update,
        .length = 1,
    };
    try header.serialize(msg[0..NetType.tls.HandshakeHeader.SIZE]);
    msg[NetType.tls.HandshakeHeader.SIZE] = 0;

    _ = try client.handshake_state.records.writeRecord(.handshake, &msg, &client.write_record_buf, &client.write_plaintext_buf);

    client.handshake_state.client_application_traffic_secret = nextTrafficSecret(
        NetType,
        client.handshake_state.cipher_suite,
        client.handshake_state.client_application_traffic_secret,
    );
    client.handshake_state.records.setWriteCipher(try cipherFromTrafficSecret(
        NetType,
        client.handshake_state.cipher_suite,
        client.handshake_state.client_application_traffic_secret,
    ));
}

pub fn sendServerKeyUpdate(comptime NetType: type, server: *NetType.tls.ServerConn) !void {
    var msg: [NetType.tls.HandshakeHeader.SIZE + 1]u8 = undefined;
    const header: NetType.tls.HandshakeHeader = .{
        .msg_type = .key_update,
        .length = 1,
    };
    try header.serialize(msg[0..NetType.tls.HandshakeHeader.SIZE]);
    msg[NetType.tls.HandshakeHeader.SIZE] = 0;

    _ = try server.handshake_state.records.writeRecord(.handshake, &msg, &server.write_record_buf, &server.write_plaintext_buf);

    server.handshake_state.server_application_traffic_secret = nextTrafficSecret(
        NetType,
        server.handshake_state.cipher_suite,
        server.handshake_state.server_application_traffic_secret,
    );
    server.handshake_state.records.setWriteCipher(try cipherFromTrafficSecret(
        NetType,
        server.handshake_state.cipher_suite,
        server.handshake_state.server_application_traffic_secret,
    ));
}
