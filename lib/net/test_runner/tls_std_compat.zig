//! TLS std-compat tests — host-only interoperability coverage.
//!
//! These tests validate interoperability between `embed-zig` TLS server paths
//! and `std.crypto.tls.Client`. They are intentionally separate from the
//! embedded-friendly TLS runner because they depend on Zig stdlib TLS and host
//! networking APIs.
//!
//! The private `run()` helper is only driven by the local `test "tls std_compat"`
//! block at the bottom of this file; it is not part of the public test-runner
//! namespace.

const std = @import("std");
const net_mod = @import("../../net.zig");
const fixtures = @import("../tls/test_fixtures.zig");

fn run() !void {
    const Net = net_mod.Make(std);
    const log = std.log.scoped(.tls_std_compat);

    log.info("=== tls std_compat start ===", .{});
    try serverInteroperatesWithStdTlsClient(Net);
    try serverInteroperatesWithStdTlsClientAcrossConfiguredTls13Suites(Net);
    log.info("=== tls std_compat done ===", .{});
}

fn serverInteroperatesWithStdTlsClient(comptime Net: type) !void {
    var ln = try Net.TcpListener.init(std.testing.allocator, .{
        .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    });
    defer ln.deinit();
    const ln_impl = try ln.as(Net.TcpListener);
    const port = try ln_impl.port();

    var server_result: ?anyerror = null;
    var server_thread = try std.Thread.spawn(.{}, struct {
        fn run(listener: *Net.TcpListener, result: *?anyerror) void {
            var conn = listener.accept() catch |err| {
                result.* = err;
                return;
            };
            errdefer conn.deinit();

            var tls_conn = Net.tls.server(std.testing.allocator, conn, .{
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
    }.run, .{ ln_impl, &server_result });
    defer server_thread.join();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = try std.net.tcpConnectToAddress(addr);
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

fn serverInteroperatesWithStdTlsClientAcrossConfiguredTls13Suites(comptime Net: type) !void {
    for ([_]Net.tls.CipherSuite{
        .TLS_AES_128_GCM_SHA256,
        .TLS_AES_256_GCM_SHA384,
        .TLS_CHACHA20_POLY1305_SHA256,
    }) |suite| {
        var ln = try Net.TcpListener.init(std.testing.allocator, .{
            .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
        });
        defer ln.deinit();
        const ln_impl = try ln.as(Net.TcpListener);
        const port = try ln_impl.port();

        var server_result: ?anyerror = null;
        var server_thread = try std.Thread.spawn(.{}, struct {
            fn run(listener: *Net.TcpListener, wanted_suite: Net.tls.CipherSuite, result: *?anyerror) void {
                var conn = listener.accept() catch |err| {
                    result.* = err;
                    return;
                };
                errdefer conn.deinit();

                var tls_conn = Net.tls.server(std.testing.allocator, conn, .{
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
        }.run, .{ ln_impl, suite, &server_result });
        defer server_thread.join();

        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const stream = try std.net.tcpConnectToAddress(addr);
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

test "tls std_compat" {
    try run();
}
