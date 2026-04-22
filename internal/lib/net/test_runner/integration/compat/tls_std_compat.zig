//! TLS std-compat tests — host-only interoperability coverage.
//!
//! These tests validate interoperability between `stdz-zig` TLS server paths
//! and `std.crypto.tls.Client`. They are intentionally separate from the
//! embedded-friendly TLS runner because they depend on Zig stdlib TLS and host
//! networking APIs.
//!
//! This runner is host-only and is intended to be invoked from `lib/net.zig`'s
//! `net/compat_tests/std` block.

const std = @import("std");
const stdz = @import("stdz");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const sockaddr_mod = @import("../../../fd/SockAddr.zig");
const fixtures = @import("../../../tls/test_fixtures.zig");
const kdf_mod = @import("../../../tls/kdf.zig");
const AddrPort = net_mod.netip.AddrPort;

pub fn make() testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            runImpl(std, t, allocator) catch |err| {
                t.logErrorf("tls_std_compat runner failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type, t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    _ = t;
    const Net = net_mod.make(lib);
    try kdfMatchesStdTlsHelpers();
    try serverInteroperatesWithStdTlsClient(Net, alloc);
    try serverInteroperatesWithStdTlsClientAcrossConfiguredTls13Suites(Net, alloc);
}

fn kdfMatchesStdTlsHelpers() !void {
    const K = kdf_mod.make(std);
    const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;
    const HkdfSha384 = std.crypto.kdf.hkdf.Hkdf(HmacSha384);

    const secret: [K.HkdfSha384.prk_length]u8 = [_]u8{0x5a} ** K.HkdfSha384.prk_length;
    const transcript: [K.Sha384.digest_length]u8 = [_]u8{0x33} ** K.Sha384.digest_length;

    const ours = K.finishedVerifyDataSha384(secret, &transcript);
    const finished_key = std.crypto.tls.hkdfExpandLabel(
        HkdfSha384,
        secret,
        "finished",
        "",
        HmacSha384.key_length,
    );
    const expected = std.crypto.tls.hmac(HmacSha384, &transcript, finished_key);

    try std.testing.expectEqualSlices(u8, &expected, &ours);
}

fn serverInteroperatesWithStdTlsClient(comptime Net: type, allocator: std.mem.Allocator) !void {
    var ln = try Net.TcpListener.init(allocator, .{
        .address = AddrPort.from4(.{ 127, 0, 0, 1 }, 0),
    });
    defer ln.deinit();
    try ln.listen();
    const ln_impl = try ln.as(Net.TcpListener);
    const port = try ln_impl.port();

    var server_result: ?anyerror = null;
    var server_thread = try std.Thread.spawn(.{}, struct {
        fn run(listener: *Net.TcpListener, tls_allocator: std.mem.Allocator, result: *?anyerror) void {
            var conn = listener.accept() catch |err| {
                result.* = err;
                return;
            };
            errdefer conn.deinit();

            var tls_conn = Net.tls.server(tls_allocator, conn, .{
                .certificates = &.{.{
                    .chain = &.{fixtures.self_signed_cert_der[0..]},
                    .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                }},
            }) catch |err| {
                result.* = err;
                return;
            };
            defer tls_conn.deinit();

            var buf: [4]u8 = undefined;
            readAll(tls_conn, &buf) catch |err| {
                result.* = err;
                return;
            };
            writeAll(tls_conn, "pong") catch |err| {
                result.* = err;
                return;
            };
            if (!std.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
        }
    }.run, .{ ln_impl, allocator, &server_result });
    defer server_thread.join();

    const stream = try tcpConnectStream(AddrPort.from4(.{ 127, 0, 0, 1 }, port));
    defer stream.close();

    var input_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var output_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;

    var input = stream.reader(&input_buf);
    var output = stream.writer(&output_buf);
    const input_io = input.interface();
    const output_io = &output.interface;
    var client = try std.crypto.tls.Client.init(input_io, output_io, .{
        .host = .no_verification,
        .ca = .no_verification,
        .read_buffer = &tls_read_buf,
        .write_buffer = &tls_write_buf,
    });

    try client.writer.writeAll("ping");
    try client.writer.flush();
    try output_io.flush();

    var resp: [4]u8 = undefined;
    try client.reader.readSliceAll(&resp);
    try std.testing.expectEqualStrings("pong", &resp);

    if (server_result) |err| return err;
}

fn serverInteroperatesWithStdTlsClientAcrossConfiguredTls13Suites(comptime Net: type, allocator: std.mem.Allocator) !void {
    for ([_]Net.tls.CipherSuite{
        .TLS_AES_128_GCM_SHA256,
        .TLS_AES_256_GCM_SHA384,
        .TLS_CHACHA20_POLY1305_SHA256,
    }) |suite| {
        var ln = try Net.TcpListener.init(allocator, .{
            .address = AddrPort.from4(.{ 127, 0, 0, 1 }, 0),
        });
        defer ln.deinit();
        try ln.listen();
        const ln_impl = try ln.as(Net.TcpListener);
        const port = try ln_impl.port();

        var server_result: ?anyerror = null;
        var server_thread = try std.Thread.spawn(.{}, struct {
            fn run(listener: *Net.TcpListener, tls_allocator: std.mem.Allocator, wanted_suite: Net.tls.CipherSuite, result: *?anyerror) void {
                var conn = listener.accept() catch |err| {
                    result.* = err;
                    return;
                };
                errdefer conn.deinit();

                var tls_conn = Net.tls.server(tls_allocator, conn, .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                    .min_version = .tls_1_3,
                    .max_version = .tls_1_3,
                    .tls13_cipher_suites = &.{wanted_suite},
                }) catch |err| {
                    result.* = err;
                    return;
                };
                defer tls_conn.deinit();

                const typed = tls_conn.as(Net.tls.ServerConn) catch unreachable;
                typed.handshake() catch |err| {
                    result.* = err;
                    return;
                };
                if (typed.handshake_state.version != .tls_1_3 or typed.handshake_state.cipher_suite != wanted_suite) {
                    result.* = error.TestUnexpectedResult;
                    return;
                }

                var buf: [4]u8 = undefined;
                readAll(tls_conn, &buf) catch |err| {
                    result.* = err;
                    return;
                };
                writeAll(tls_conn, "pong") catch |err| {
                    result.* = err;
                    return;
                };
                if (!std.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
            }
        }.run, .{ ln_impl, allocator, suite, &server_result });
        defer server_thread.join();

        const stream = try tcpConnectStream(AddrPort.from4(.{ 127, 0, 0, 1 }, port));
        defer stream.close();

        var input_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var output_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;

        var input = stream.reader(&input_buf);
        var output = stream.writer(&output_buf);
        const input_io = input.interface();
        const output_io = &output.interface;
        var client = try std.crypto.tls.Client.init(input_io, output_io, .{
            .host = .no_verification,
            .ca = .no_verification,
            .read_buffer = &tls_read_buf,
            .write_buffer = &tls_write_buf,
        });

        try client.writer.writeAll("ping");
        try client.writer.flush();
        try output_io.flush();

        var resp: [4]u8 = undefined;
        try client.reader.readSliceAll(&resp);
        try std.testing.expectEqualStrings("pong", &resp);

        if (server_result) |err| return err;
    }
}

fn readAll(conn: net_mod.Conn, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try conn.read(buf[filled..]);
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

fn writeAll(conn: net_mod.Conn, buf: []const u8) !void {
    var written: usize = 0;
    while (written < buf.len) {
        const n = try conn.write(buf[written..]);
        if (n == 0) return error.BrokenPipe;
        written += n;
    }
}

fn tcpConnectStream(addr: AddrPort) !std.net.Stream {
    const SockAddr = sockaddr_mod.SockAddr(std);
    const encoded = try SockAddr.encode(addr);
    const fd = try std.posix.socket(encoded.family, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(fd);
    try std.posix.connect(fd, @ptrCast(&encoded.storage), encoded.len);
    return .{ .handle = fd };
}
