//! TLS test runner — deterministic local integration tests.
//!
//! These tests exercise the generic `net.tls` client and server paths using
//! local loopback listeners so the same behavior can be re-run on embedded
//! targets. Public-network smoke coverage is available separately via
//! `runPublicAliDnsSmoke`, which pins exact TLS versions against
//! `public.alidns.com:853` in sequence.
//!
//! Usage:
//!   try @import("net/test_runner/tls.zig").run(lib);
//!   try @import("net/test_runner/tls.zig").runPublicAliDnsSmoke(lib); // optional

const net_mod = @import("../../net.zig");
const fixtures = @import("../tls/test_fixtures.zig");

pub fn run(comptime lib: type) !void {
    const Net = net_mod.Make(lib);
    const Addr = lib.net.Address;
    const Thread = lib.Thread;
    const testing = lib.testing;
    const log = lib.log.scoped(.tls);

    const Runner = struct {
        const StartGate = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            ready: usize = 0,
            target: usize,

            fn init(target: usize) @This() {
                return .{ .target = target };
            }

            fn wait(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();

                self.ready += 1;
                if (self.ready == self.target) {
                    self.cond.broadcast();
                    return;
                }
                while (self.ready < self.target) self.cond.wait(&self.mutex);
            }
        };

        const ReadTask = struct {
            gate: *StartGate,
            conn: net_mod.Conn,
            expected: []const u8,
            output: []u8,
            result: *?anyerror,
        };

        const WriteTask = struct {
            gate: *StartGate,
            conn: net_mod.Conn,
            payload: []const u8,
            result: *?anyerror,
        };

        fn localLoopbackVersions() !void {
            try runLoopbackCase(
                Net,
                .tls_1_2,
                .tls_1_2,
                .tls_1_2,
                .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                null,
                null,
            );
            try runLoopbackCase(Net, .tls_1_2, .tls_1_3, .tls_1_3, null, null, null);
            try runLoopbackCase(Net, .tls_1_3, .tls_1_3, .tls_1_3, null, null, null);
        }

        fn tls13ConfiguredSuites() !void {
            for ([_]Net.tls.CipherSuite{
                .TLS_AES_128_GCM_SHA256,
                .TLS_AES_256_GCM_SHA384,
                .TLS_CHACHA20_POLY1305_SHA256,
            }) |suite| {
                try runLoopbackCase(
                    Net,
                    .tls_1_3,
                    .tls_1_3,
                    .tls_1_3,
                    suite,
                    &.{suite},
                    &.{suite},
                );
            }
        }

        fn serverConnHandlesClientKeyUpdate() !void {
            for ([_]Net.tls.CipherSuite{
                .TLS_AES_128_GCM_SHA256,
                .TLS_AES_256_GCM_SHA384,
                .TLS_CHACHA20_POLY1305_SHA256,
            }) |suite| {
                var ln = try Net.TcpListener.init(testing.allocator, .{
                    .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
                });
                defer ln.deinit();
                const ln_impl = try ln.as(Net.TcpListener);
                const port = try ln_impl.port();

                var server_result: ?anyerror = null;
                var server_thread = try Thread.spawn(.{}, struct {
                    fn run(listener: *Net.TcpListener, wanted_suite: Net.tls.CipherSuite, result: *?anyerror) void {
                        var conn = listener.accept() catch |err| {
                            result.* = err;
                            return;
                        };
                        errdefer conn.deinit();

                        var tls_conn = Net.tls.server(testing.allocator, conn, .{
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
                        if (!lib.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
                    }
                }.run, .{ ln_impl, suite, &server_result });
                defer server_thread.join();

                var d = Net.Dialer.init(testing.allocator, .{});
                var client_conn = try d.dial(.tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
                var client_conn_owned = true;
                errdefer if (client_conn_owned) client_conn.deinit();

                var tls_client = try Net.tls.client(testing.allocator, client_conn, .{
                    .server_name = "example.com",
                    .verification = .self_signed,
                    .min_version = .tls_1_3,
                    .max_version = .tls_1_3,
                    .tls13_cipher_suites = &.{suite},
                });
                client_conn_owned = false;
                defer tls_client.deinit();

                const typed = try tls_client.as(Net.tls.Conn);
                try typed.handshake();
                try testing.expectEqual(Net.tls.ProtocolVersion.tls_1_3, typed.handshake_state.version);
                try testing.expectEqual(suite, typed.handshake_state.cipher_suite);

                try sendClientKeyUpdate(Net, typed);
                try writeAll(tls_client, "ping");

                var resp: [4]u8 = undefined;
                try readAll(tls_client, &resp);
                try testing.expectEqualStrings("pong", &resp);

                if (server_result) |err| return err;
            }
        }

        fn clientConnHandlesServerKeyUpdate() !void {
            for ([_]Net.tls.CipherSuite{
                .TLS_AES_128_GCM_SHA256,
                .TLS_AES_256_GCM_SHA384,
                .TLS_CHACHA20_POLY1305_SHA256,
            }) |suite| {
                var ln = try Net.TcpListener.init(testing.allocator, .{
                    .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
                });
                defer ln.deinit();
                const ln_impl = try ln.as(Net.TcpListener);
                const port = try ln_impl.port();

                var server_result: ?anyerror = null;
                var server_thread = try Thread.spawn(.{}, struct {
                    fn run(listener: *Net.TcpListener, wanted_suite: Net.tls.CipherSuite, result: *?anyerror) void {
                        var conn = listener.accept() catch |err| {
                            result.* = err;
                            return;
                        };
                        errdefer conn.deinit();

                        var tls_conn = Net.tls.server(testing.allocator, conn, .{
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

                        sendServerKeyUpdate(Net, typed) catch |err| {
                            result.* = err;
                            return;
                        };
                        writeAll(tls_conn, "pong") catch |err| {
                            result.* = err;
                            return;
                        };

                        var buf: [4]u8 = undefined;
                        readAll(tls_conn, &buf) catch |err| {
                            result.* = err;
                            return;
                        };
                        if (!lib.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
                    }
                }.run, .{ ln_impl, suite, &server_result });
                defer server_thread.join();

                var d = Net.Dialer.init(testing.allocator, .{});
                var client_conn = try d.dial(.tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
                var client_conn_owned = true;
                errdefer if (client_conn_owned) client_conn.deinit();

                var tls_client = try Net.tls.client(testing.allocator, client_conn, .{
                    .server_name = "example.com",
                    .verification = .self_signed,
                    .min_version = .tls_1_3,
                    .max_version = .tls_1_3,
                    .tls13_cipher_suites = &.{suite},
                });
                client_conn_owned = false;
                defer tls_client.deinit();

                const typed = try tls_client.as(Net.tls.Conn);
                try typed.handshake();
                try testing.expectEqual(Net.tls.ProtocolVersion.tls_1_3, typed.handshake_state.version);
                try testing.expectEqual(suite, typed.handshake_state.cipher_suite);

                var resp: [4]u8 = undefined;
                try readAll(tls_client, &resp);
                try testing.expectEqualStrings("pong", &resp);

                try writeAll(tls_client, "ping");

                if (server_result) |err| return err;
            }
        }

        fn closeSendsCloseNotifyToPeer() !void {
            var ln = try Net.TcpListener.init(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer ln.deinit();
            const ln_impl = try ln.as(Net.TcpListener);
            const port = try ln_impl.port();

            var server_result: ?anyerror = null;
            var server_thread = try Thread.spawn(.{}, struct {
                fn run(listener: *Net.TcpListener, result: *?anyerror) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    errdefer conn.deinit();

                    var tls_conn = Net.tls.server(testing.allocator, conn, .{
                        .certificates = &.{.{
                            .chain = &.{fixtures.self_signed_cert_der[0..]},
                            .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                        }},
                        .min_version = .tls_1_3,
                        .max_version = .tls_1_3,
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
                    if (!lib.mem.eql(u8, &buf, "ping")) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    var eof_buf: [1]u8 = undefined;
                    _ = tls_conn.read(&eof_buf) catch |err| {
                        if (err == error.EndOfStream) return;
                        result.* = err;
                        return;
                    };
                    result.* = error.TestUnexpectedResult;
                }
            }.run, .{ ln_impl, &server_result });
            defer server_thread.join();

            var d = Net.Dialer.init(testing.allocator, .{});
            var client_conn = try d.dial(.tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            var client_conn_owned = true;
            errdefer if (client_conn_owned) client_conn.deinit();

            var tls_client = try Net.tls.client(testing.allocator, client_conn, .{
                .server_name = "example.com",
                .verification = .self_signed,
                .min_version = .tls_1_3,
                .max_version = .tls_1_3,
            });
            client_conn_owned = false;
            defer tls_client.deinit();

            try writeAll(tls_client, "ping");
            tls_client.close();

            if (server_result) |err| return err;
        }

        fn listenerAcceptsTlsClient() !void {
            var ln = try Net.tls.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            }, .{
                .certificates = &.{.{
                    .chain = &.{fixtures.self_signed_cert_der[0..]},
                    .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                }},
            });
            defer ln.deinit();

            const tls_listener = try ln.as(Net.tls.Listener);
            const tcp_impl = try tls_listener.inner.as(Net.TcpListener);
            const port = try tcp_impl.port();

            var server_result: ?anyerror = null;
            var server_thread = try Thread.spawn(.{}, struct {
                fn run(listener: *Net.tls.Listener, result: *?anyerror) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();

                    const typed = conn.as(Net.tls.ServerConn) catch {
                        result.* = error.TestUnexpectedResult;
                        return;
                    };
                    typed.handshake() catch |err| {
                        result.* = err;
                        return;
                    };

                    var buf: [4]u8 = undefined;
                    readAll(conn, &buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    writeAll(conn, "pong") catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!lib.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
                }
            }.run, .{ tls_listener, &server_result });
            defer server_thread.join();

            var d = Net.Dialer.init(testing.allocator, .{});
            var client_conn = try d.dial(.tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            var client_conn_owned = true;
            errdefer if (client_conn_owned) client_conn.deinit();

            var tls_client = try Net.tls.client(testing.allocator, client_conn, .{
                .server_name = "example.com",
                .verification = .self_signed,
            });
            client_conn_owned = false;
            defer tls_client.deinit();

            try writeAll(tls_client, "ping");
            var resp: [4]u8 = undefined;
            try readAll(tls_client, &resp);
            try testing.expectEqualStrings("pong", &resp);

            if (server_result) |err| return err;
        }

        fn dialerConnectsToTlsListener() !void {
            var ln = try Net.tls.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            }, .{
                .certificates = &.{.{
                    .chain = &.{fixtures.self_signed_cert_der[0..]},
                    .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                }},
            });
            defer ln.deinit();

            const tls_listener = try ln.as(Net.tls.Listener);
            const tcp_impl = try tls_listener.inner.as(Net.TcpListener);
            const port = try tcp_impl.port();

            var server_result: ?anyerror = null;
            var server_thread = try Thread.spawn(.{}, struct {
                fn run(listener: *Net.tls.Listener, result: *?anyerror) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();

                    const typed = conn.as(Net.tls.ServerConn) catch {
                        result.* = error.TestUnexpectedResult;
                        return;
                    };
                    typed.handshake() catch |err| {
                        result.* = err;
                        return;
                    };

                    var buf: [4]u8 = undefined;
                    readAll(conn, &buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    writeAll(conn, "pong") catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!lib.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
                }
            }.run, .{ tls_listener, &server_result });
            defer server_thread.join();

            const net_dialer = Net.Dialer.init(testing.allocator, .{});
            const d = Net.tls.Dialer.init(net_dialer, .{
                .server_name = "example.com",
                .verification = .self_signed,
            });
            var conn = try d.dial(.tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            defer conn.deinit();

            const typed = try conn.as(Net.tls.Conn);
            try typed.handshake();

            try writeAll(conn, "ping");
            var resp: [4]u8 = undefined;
            try readAll(conn, &resp);
            try testing.expectEqualStrings("pong", &resp);

            if (server_result) |err| return err;
        }

        fn connSupportsConcurrentBidirectionalReadWrite() !void {
            var ln = try Net.TcpListener.init(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer ln.deinit();
            const ln_impl = try ln.as(Net.TcpListener);
            const port = try ln_impl.port();

            var server_result: ?anyerror = null;
            var server_thread = try Thread.spawn(.{}, struct {
                fn run(listener: *Net.TcpListener, result: *?anyerror) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    errdefer conn.deinit();

                    var tls_conn = Net.tls.server(testing.allocator, conn, .{
                        .certificates = &.{.{
                            .chain = &.{fixtures.self_signed_cert_der[0..]},
                            .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                        }},
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

                    tls_conn.setReadTimeout(10_000);
                    tls_conn.setWriteTimeout(10_000);

                    const inbound_len = Net.tls.MAX_PLAINTEXT_LEN * 3 + 257;
                    const outbound_len = Net.tls.MAX_PLAINTEXT_LEN * 2 + 113;

                    const expected_from_client = testing.allocator.alloc(u8, inbound_len) catch |err| {
                        result.* = err;
                        return;
                    };
                    defer testing.allocator.free(expected_from_client);
                    fillPattern(expected_from_client, 17);

                    const outbound = testing.allocator.alloc(u8, outbound_len) catch |err| {
                        result.* = err;
                        return;
                    };
                    defer testing.allocator.free(outbound);
                    fillPattern(outbound, 91);

                    const received = testing.allocator.alloc(u8, inbound_len) catch |err| {
                        result.* = err;
                        return;
                    };
                    defer testing.allocator.free(received);

                    var gate = StartGate.init(2);
                    var read_result: ?anyerror = null;
                    var write_result: ?anyerror = null;

                    var reader_thread = Thread.spawn(.{}, reader, .{ReadTask{
                        .gate = &gate,
                        .conn = tls_conn,
                        .expected = expected_from_client,
                        .output = received,
                        .result = &read_result,
                    }}) catch |err| {
                        result.* = err;
                        return;
                    };

                    var writer_thread = Thread.spawn(.{}, writer, .{WriteTask{
                        .gate = &gate,
                        .conn = tls_conn,
                        .payload = outbound,
                        .result = &write_result,
                    }}) catch |err| {
                        result.* = err;
                        return;
                    };
                    reader_thread.join();
                    writer_thread.join();

                    if (read_result) |err| {
                        result.* = err;
                        return;
                    }
                    if (write_result) |err| {
                        result.* = err;
                        return;
                    }
                }
            }.run, .{ ln_impl, &server_result });

            var d = Net.Dialer.init(testing.allocator, .{});
            var client_conn = try d.dial(.tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port));
            var client_conn_owned = true;
            errdefer if (client_conn_owned) client_conn.deinit();

            var tls_client = try Net.tls.client(testing.allocator, client_conn, .{
                .server_name = "example.com",
                .verification = .self_signed,
                .min_version = .tls_1_3,
                .max_version = .tls_1_3,
            });
            client_conn_owned = false;
            defer tls_client.deinit();

            const typed = try tls_client.as(Net.tls.Conn);
            try typed.handshake();

            tls_client.setReadTimeout(10_000);
            tls_client.setWriteTimeout(10_000);

            const outbound_len = Net.tls.MAX_PLAINTEXT_LEN * 3 + 257;
            const inbound_len = Net.tls.MAX_PLAINTEXT_LEN * 2 + 113;

            const outbound = try testing.allocator.alloc(u8, outbound_len);
            defer testing.allocator.free(outbound);
            fillPattern(outbound, 17);

            const expected_from_server = try testing.allocator.alloc(u8, inbound_len);
            defer testing.allocator.free(expected_from_server);
            fillPattern(expected_from_server, 91);

            const received = try testing.allocator.alloc(u8, inbound_len);
            defer testing.allocator.free(received);

            var gate = StartGate.init(2);
            var read_result: ?anyerror = null;
            var write_result: ?anyerror = null;

            var reader_thread = try Thread.spawn(.{}, reader, .{ReadTask{
                .gate = &gate,
                .conn = tls_client,
                .expected = expected_from_server,
                .output = received,
                .result = &read_result,
            }});

            var writer_thread = try Thread.spawn(.{}, writer, .{WriteTask{
                .gate = &gate,
                .conn = tls_client,
                .payload = outbound,
                .result = &write_result,
            }});
            reader_thread.join();
            writer_thread.join();
            server_thread.join();

            if (read_result) |err| return err;
            if (write_result) |err| return err;
            if (server_result) |err| return err;
        }

        fn dialerRejectsUdp() !void {
            const net_dialer = Net.Dialer.init(testing.allocator, .{});
            const d = Net.tls.Dialer.init(net_dialer, .{
                .server_name = "example.com",
                .insecure_skip_verify = true,
            });

            try testing.expectError(
                error.UnsupportedNetwork,
                d.dial(.udp, Addr.initIp4(.{ 127, 0, 0, 1 }, 1)),
            );
        }

        fn invalidListenerConfigRejected() !void {
            log.info("tls listener invalid config rejected", .{});

            var inner = try Net.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer inner.deinit();

            try testing.expectError(error.InvalidConfig, Net.tls.newListener(testing.allocator, inner, .{
                .certificates = &.{},
            }));
        }

        fn runLoopbackCase(
            comptime NetType: type,
            min_version: NetType.tls.ProtocolVersion,
            max_version: NetType.tls.ProtocolVersion,
            expected_version: NetType.tls.ProtocolVersion,
            expected_suite: ?NetType.tls.CipherSuite,
            client_tls13_cipher_suites: ?[]const NetType.tls.CipherSuite,
            server_tls13_cipher_suites: ?[]const NetType.tls.CipherSuite,
        ) !void {
            log.info(
                "loopback self-signed: min={s}, max={s}",
                .{ min_version.name(), max_version.name() },
            );

            var server_config: NetType.tls.ServerConfig = .{
                .certificates = &.{.{
                    .chain = &.{fixtures.self_signed_cert_der[0..]},
                    .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                }},
                .min_version = min_version,
                .max_version = max_version,
            };
            if (server_tls13_cipher_suites) |suites| {
                server_config.tls13_cipher_suites = suites;
            }

            var ln = try NetType.tls.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            }, server_config);
            defer ln.deinit();

            const tls_listener = try ln.as(NetType.tls.Listener);
            const tcp_listener = try tls_listener.inner.as(NetType.TcpListener);
            const port = try tcp_listener.port();

            var server_result: ?anyerror = null;
            var server_thread = try Thread.spawn(.{}, struct {
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
                    if (!lib.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
                }
            }.run, .{ tls_listener, expected_version, expected_suite, &server_result });
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

            var conn = try NetType.tls.dial(testing.allocator, .tcp, Addr.initIp4(.{ 127, 0, 0, 1 }, port), client_config);
            defer conn.deinit();

            const typed = try conn.as(NetType.tls.Conn);
            try typed.handshake();
            try testing.expectEqual(expected_version, typed.handshake_state.version);
            if (expected_suite) |suite| {
                try testing.expectEqual(suite, typed.handshake_state.cipher_suite);
            }

            try writeAll(conn, "ping");
            var resp: [4]u8 = undefined;
            try readAll(conn, &resp);
            try testing.expectEqualStrings("pong", &resp);
            if (server_result) |err| return err;
        }

        fn reader(task: ReadTask) void {
            task.gate.wait();
            readAll(task.conn, task.output) catch |err| {
                task.result.* = err;
                return;
            };
            if (!lib.mem.eql(u8, task.expected, task.output)) {
                task.result.* = error.TestUnexpectedResult;
            }
        }

        fn writer(task: WriteTask) void {
            task.gate.wait();
            writeAll(task.conn, task.payload) catch |err| {
                task.result.* = err;
            };
        }

        fn fillPattern(buf: []u8, seed: u8) void {
            for (buf, 0..) |*byte, i| {
                byte.* = @truncate((i * 131 + seed) % 251);
            }
        }
    };

    log.info("=== tls local test_runner start ===", .{});
    try Runner.localLoopbackVersions();
    try Runner.tls13ConfiguredSuites();
    try Runner.serverConnHandlesClientKeyUpdate();
    try Runner.clientConnHandlesServerKeyUpdate();
    try Runner.closeSendsCloseNotifyToPeer();
    try Runner.listenerAcceptsTlsClient();
    try Runner.dialerConnectsToTlsListener();
    try Runner.connSupportsConcurrentBidirectionalReadWrite();
    try Runner.dialerRejectsUdp();
    try Runner.invalidListenerConfigRejected();
    log.info("=== tls local test_runner done ===", .{});
}

pub fn runPublicAliDnsSmoke(comptime lib: type) !void {
    const Net = net_mod.Make(lib);
    const Resolver = Net.Resolver;
    const Addr = lib.net.Address;
    const testing = lib.testing;
    const log = lib.log.scoped(.tls);

    log.info("=== tls public smoke start ===", .{});
    var bundle: lib.crypto.Certificate.Bundle = .{};
    defer bundle.deinit(testing.allocator);
    try bundle.rescan(testing.allocator);

    const server_addr = comptime Addr.parseIp(Resolver.dns.ali.v4_1, 853) catch unreachable;
    inline for ([_]Net.tls.ProtocolVersion{
        .tls_1_2,
        .tls_1_3,
    }) |version| {
        try runAliDnsPinnedVersionCase(lib, Net, server_addr, &bundle, version);
    }
    log.info("=== tls public smoke done ===", .{});
}

fn runAliDnsPinnedVersionCase(
    comptime lib: type,
    comptime NetType: type,
    server_addr: anytype,
    bundle: *const lib.crypto.Certificate.Bundle,
    version: NetType.tls.ProtocolVersion,
) !void {
    const testing = lib.testing;
    const log = lib.log.scoped(.tls);

    log.info(
        "public.alidns.com pinned version={s}",
        .{version.name()},
    );

    var tls_conn = try NetType.tls.dial(testing.allocator, .tcp, server_addr, .{
        .server_name = "public.alidns.com",
        .root_cas = bundle,
        .min_version = version,
        .max_version = version,
    });
    defer tls_conn.deinit();

    const tls_impl = try tls_conn.as(NetType.tls.Conn);
    try tls_impl.handshake();
    try testing.expectEqual(version, tls_impl.handshake_state.version);
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

fn sendClientKeyUpdate(comptime NetType: type, client: *NetType.tls.Conn) !void {
    var msg: [NetType.tls.HandshakeHeader.SIZE + 1]u8 = undefined;
    const header: NetType.tls.HandshakeHeader = .{
        .msg_type = .key_update,
        .length = 1,
    };
    try header.serialize(msg[0..NetType.tls.HandshakeHeader.SIZE]);
    msg[NetType.tls.HandshakeHeader.SIZE] = 0;

    _ = try client.handshake_state.records.writeRecord(.handshake, &msg, &client.write_record_buf);

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

fn sendServerKeyUpdate(comptime NetType: type, server: *NetType.tls.ServerConn) !void {
    var msg: [NetType.tls.HandshakeHeader.SIZE + 1]u8 = undefined;
    const header: NetType.tls.HandshakeHeader = .{
        .msg_type = .key_update,
        .length = 1,
    };
    try header.serialize(msg[0..NetType.tls.HandshakeHeader.SIZE]);
    msg[NetType.tls.HandshakeHeader.SIZE] = 0;

    _ = try server.handshake_state.records.writeRecord(.handshake, &msg, &server.write_record_buf);

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
