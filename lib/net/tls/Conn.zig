const NetConn = @import("../Conn.zig");

pub fn Conn(comptime lib: type) type {
    const common = @import("common.zig").Make(lib);
    const alert = @import("alert.zig").Make(lib);
    const kdf = @import("kdf.zig").Make(lib);
    const record = @import("record.zig").Make(lib);
    const client_handshake = @import("client_handshake.zig").Make(lib);
    const Allocator = lib.mem.Allocator;
    const Mutex = lib.Thread.Mutex;
    const BundleRescanReturn = @typeInfo(@TypeOf(lib.crypto.Certificate.Bundle.rescan)).@"fn".return_type.?;
    const BundleRescanError = @typeInfo(BundleRescanReturn).error_union.error_set;

    return struct {
        pub const Config = struct {
            server_name: []const u8,
            insecure_skip_verify: bool = false,
            root_cas: ?*const lib.crypto.Certificate.Bundle = null,
            min_version: common.ProtocolVersion = .tls_1_2,
            max_version: common.ProtocolVersion = .tls_1_3,
            verification: ?client_handshake.VerificationMode = null,
            tls13_cipher_suites: []const common.CipherSuite = &common.DEFAULT_TLS13_CIPHER_SUITES,
        };

        pub const HandshakeError = client_handshake.HandshakeError;
        pub const VerificationMode = client_handshake.VerificationMode;
        pub const InitError = Allocator.Error || HandshakeError || BundleRescanError || error{InvalidConfig};
        
        allocator: Allocator,
        inner: NetConn,
        handshake_state: client_handshake.ClientHandshake(NetConn),
        owned_root_cas: ?lib.crypto.Certificate.Bundle = null,
        handshake_complete: bool = false,
        closed: bool = false,
        handshake_mu: Mutex = .{},
        read_mu: Mutex = .{},
        write_mu: Mutex = .{},
        pending_plaintext: [common.MAX_PLAINTEXT_LEN]u8 = undefined,
        pending_start: usize = 0,
        pending_end: usize = 0,
        read_record_buf: [common.MAX_CIPHERTEXT_LEN_TLS12]u8 = undefined,
        write_record_buf: [common.MAX_CIPHERTEXT_LEN_TLS12]u8 = undefined,
        plaintext_buf: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined,
        handshake_buf: [common.MAX_HANDSHAKE_LEN]u8 = undefined,

        const Self = @This();

        pub fn handshake(self: *Self) HandshakeError!void {
            self.handshake_mu.lock();
            defer self.handshake_mu.unlock();

            if (self.handshake_complete) return;

            if (self.handshake_state.state == .initial) {
                _ = try self.handshake_state.sendClientHello(&self.handshake_buf, &self.write_record_buf);
            }

            while (!self.handshake_complete) {
                const res = self.handshake_state.records.readRecord(&self.read_record_buf, &self.plaintext_buf) catch {
                    return error.RecordIoFailed;
                };
                switch (res.content_type) {
                    .handshake => self.handshake_state.processHandshake(self.plaintext_buf[0..res.length]) catch |err| {
                        return self.failHandshake(err);
                    },
                    .change_cipher_spec => {
                        self.handshake_state.processChangeCipherSpec(self.plaintext_buf[0..res.length]) catch |err| {
                            return self.failHandshake(err);
                        };
                        continue;
                    },
                    .alert => return self.mapAlert(self.plaintext_buf[0..res.length]),
                    else => return self.failHandshake(error.UnexpectedMessage),
                }

                if (self.handshake_state.shouldSendClientFinished()) {
                    self.handshake_state.writeClientFlight(&self.handshake_buf, &self.write_record_buf) catch |err| {
                        return self.failHandshake(err);
                    };
                }
                if (self.handshake_state.state == .connected) {
                    self.handshake_complete = true;
                }
            }
        }

        pub fn read(self: *Self, buf: []u8) NetConn.ReadError!usize {
            if (buf.len == 0) return 0;
            self.handshake() catch return error.Unexpected;

            self.read_mu.lock();
            var read_locked = true;
            defer if (read_locked) self.read_mu.unlock();

            if (self.pending_start < self.pending_end) {
                return self.readPending(buf);
            }

            while (true) {
                const res = self.handshake_state.records.readRecord(&self.read_record_buf, &self.plaintext_buf) catch {
                    return error.Unexpected;
                };
                switch (res.content_type) {
                    .application_data => {
                        @memcpy(self.pending_plaintext[0..res.length], self.plaintext_buf[0..res.length]);
                        self.pending_start = 0;
                        self.pending_end = res.length;
                        return self.readPending(buf);
                    },
                    .alert => return self.mapReadAlert(self.plaintext_buf[0..res.length]),
                    .change_cipher_spec => continue,
                    .handshake => {
                        const should_send_key_update = try self.consumePostHandshake(self.plaintext_buf[0..res.length]);
                        if (should_send_key_update) {
                            self.read_mu.unlock();
                            read_locked = false;
                            self.sendKeyUpdate() catch |err| {
                                self.read_mu.lock();
                                read_locked = true;
                                return err;
                            };
                            self.read_mu.lock();
                            read_locked = true;
                        }
                        continue;
                    },
                    else => return error.Unexpected,
                }
            }
        }

        pub fn readAll(self: *Self, buf: []u8) NetConn.ReadError!void {
            var filled: usize = 0;
            while (filled < buf.len) {
                const n = try self.read(buf[filled..]);
                if (n == 0) return error.EndOfStream;
                filled += n;
            }
        }

        pub fn write(self: *Self, buf: []const u8) NetConn.WriteError!usize {
            self.handshake() catch return error.Unexpected;
            if (buf.len == 0) return 0;

            self.write_mu.lock();
            defer self.write_mu.unlock();

            const chunk_len = @min(buf.len, common.MAX_PLAINTEXT_LEN);
            _ = self.handshake_state.records.writeRecord(.application_data, buf[0..chunk_len], &self.write_record_buf) catch {
                return error.Unexpected;
            };
            return chunk_len;
        }

        pub fn writeAll(self: *Self, buf: []const u8) NetConn.WriteError!void {
            var written: usize = 0;
            while (written < buf.len) {
                written += try self.write(buf[written..]);
            }
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            if (self.handshake_complete) self.sendCloseNotify();
            self.inner.close();
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.inner.deinit();
            if (self.owned_root_cas) |*bundle| bundle.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn setReadTimeout(self: *Self, ms: ?u32) void {
            self.inner.setReadTimeout(ms);
        }

        pub fn setWriteTimeout(self: *Self, ms: ?u32) void {
            self.inner.setWriteTimeout(ms);
        }

        fn readPending(self: *Self, buf: []u8) usize {
            const n = @min(buf.len, self.pending_end - self.pending_start);
            @memcpy(buf[0..n], self.pending_plaintext[self.pending_start..][0..n]);
            self.pending_start += n;
            if (self.pending_start == self.pending_end) {
                self.pending_start = 0;
                self.pending_end = 0;
            }
            return n;
        }

        fn consumePostHandshake(self: *Self, data: []const u8) NetConn.ReadError!bool {
            var pos: usize = 0;
            var should_send_key_update = false;
            while (pos < data.len) {
                if (pos + common.HandshakeHeader.SIZE > data.len) return error.Unexpected;
                const header = common.HandshakeHeader.parse(data[pos .. pos + common.HandshakeHeader.SIZE]) catch {
                    return error.Unexpected;
                };
                const total_len = common.HandshakeHeader.SIZE + header.length;
                if (pos + total_len > data.len) return error.Unexpected;
                switch (header.msg_type) {
                    .new_session_ticket => {},
                    .key_update => {
                        if (try self.handleKeyUpdate(data[pos + common.HandshakeHeader.SIZE ..][0..header.length])) {
                            should_send_key_update = true;
                        }
                    },
                    else => return error.Unexpected,
                }
                pos += total_len;
            }
            return should_send_key_update;
        }

        fn handleKeyUpdate(self: *Self, payload: []const u8) NetConn.ReadError!bool {
            if (self.handshake_state.version != .tls_1_3) return error.Unexpected;
            if (payload.len != 1 or payload[0] > 1) return error.Unexpected;

            self.handshake_state.server_application_traffic_secret = try nextTrafficSecret(
                self,
                self.handshake_state.server_application_traffic_secret,
            );
            self.handshake_state.records.setReadCipher(
                try self.cipherFromTrafficSecret(self.tls13Secret(&self.handshake_state.server_application_traffic_secret)),
            );
            return payload[0] == 1;
        }

        fn sendKeyUpdate(self: *Self) NetConn.ReadError!void {
            self.write_mu.lock();
            defer self.write_mu.unlock();

            const total_len = common.HandshakeHeader.SIZE + 1;
            const header: common.HandshakeHeader = .{
                .msg_type = .key_update,
                .length = 1,
            };
            header.serialize(self.handshake_buf[0..common.HandshakeHeader.SIZE]) catch return error.Unexpected;
            self.handshake_buf[common.HandshakeHeader.SIZE] = 0;

            _ = self.handshake_state.records.writeRecord(
                .handshake,
                self.handshake_buf[0..total_len],
                &self.write_record_buf,
            ) catch return error.Unexpected;

            self.handshake_state.client_application_traffic_secret = try nextTrafficSecret(
                self,
                self.handshake_state.client_application_traffic_secret,
            );
            self.handshake_state.records.setWriteCipher(
                try self.cipherFromTrafficSecret(self.tls13Secret(&self.handshake_state.client_application_traffic_secret)),
            );
        }

        fn nextTrafficSecret(
            self: *Self,
            secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
        ) NetConn.ReadError![kdf.MAX_TLS13_SECRET_LEN]u8 {
            const profile = self.tls13Profile();
            var next = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN;
            kdf.hkdfExpandLabelIntoProfile(
                profile,
                next[0..profile.secretLength()],
                secret[0..profile.secretLength()],
                "traffic upd",
                "",
            );
            return next;
        }

        fn cipherFromTrafficSecret(
            self: *Self,
            traffic_secret: []const u8,
        ) NetConn.ReadError!record.CipherState() {
            const suite = self.handshake_state.cipher_suite;
            const profile = self.tls13Profile();
            const key_len = suite.keyLength();
            if (key_len == 0 or key_len > 32) return error.Unexpected;

            var iv: [12]u8 = undefined;
            kdf.hkdfExpandLabelIntoProfile(profile, &iv, traffic_secret, "iv", "");
            var key = [_]u8{0} ** 32;
            switch (key_len) {
                16 => {
                    kdf.hkdfExpandLabelIntoProfile(profile, key[0..16], traffic_secret, "key", "");
                },
                32 => {
                    kdf.hkdfExpandLabelIntoProfile(profile, key[0..32], traffic_secret, "key", "");
                },
                else => return error.Unexpected,
            }

            return record.CipherState().init(suite, key[0..key_len], &iv) catch error.Unexpected;
        }

        fn tls13Profile(self: *Self) common.Tls13CipherProfile {
            return self.handshake_state.cipher_suite.tls13Profile() orelse unreachable;
        }

        fn tls13Secret(
            self: *Self,
            secret: *const [kdf.MAX_TLS13_SECRET_LEN]u8,
        ) []const u8 {
            const profile = self.tls13Profile();
            return secret[0..profile.secretLength()];
        }

        fn mapAlert(_: *Self, data: []const u8) HandshakeError {
            const parsed = alert.parseAlert(data) catch return error.InvalidHandshake;
            return switch (parsed.description) {
                .unknown_ca => error.UnknownCa,
                else => error.InvalidHandshake,
            };
        }

        fn mapReadAlert(_: *Self, data: []const u8) NetConn.ReadError {
            const parsed = alert.parseAlert(data) catch return error.Unexpected;
            return switch (parsed.description) {
                .close_notify => error.EndOfStream,
                else => error.Unexpected,
            };
        }

        fn failHandshake(self: *Self, err: HandshakeError) HandshakeError {
            self.sendFatalAlert(handshakeErrorToAlert(err));
            return err;
        }

        fn sendCloseNotify(self: *Self) void {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.handshake_state.records.sendAlert(.warning, .close_notify, &self.write_record_buf) catch {};
        }

        fn sendFatalAlert(self: *Self, description: common.AlertDescription) void {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.handshake_state.records.sendAlert(.fatal, description, &self.write_record_buf) catch {};
        }

        fn handshakeErrorToAlert(err: HandshakeError) common.AlertDescription {
            return switch (err) {
                error.UnknownCa => .unknown_ca,
                error.UnsupportedVersion => .protocol_version,
                error.UnsupportedCipherSuite, error.UnsupportedGroup, error.KeyExchangeFailed => .handshake_failure,
                error.MissingExtension => .missing_extension,
                error.UnexpectedMessage => .unexpected_message,
                error.BadRecordMac => .bad_record_mac,
                error.RecordIoFailed => .internal_error,
                else => .decode_error,
            };
        }

        pub fn init(allocator: Allocator, inner: NetConn, config: Config) InitError!NetConn {
            try validateConfig(config);

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .inner = inner,
                .handshake_state = undefined,
            };

            errdefer if (self.owned_root_cas) |*bundle| bundle.deinit(allocator);

            const verification = try self.resolveVerificationMode(config);
            self.handshake_state = try client_handshake.ClientHandshake(NetConn).initWithOptions(inner, .{
                .hostname = config.server_name,
                .allocator = allocator,
                .verification = verification,
                .min_version = config.min_version,
                .max_version = config.max_version,
                .tls13_cipher_suites = config.tls13_cipher_suites,
            });
            return NetConn.init(self);
        }

        fn validateConfig(config: Config) InitError!void {
            if (config.server_name.len == 0) return error.InvalidConfig;
            if (@intFromEnum(config.min_version) > @intFromEnum(config.max_version)) return error.InvalidConfig;
        }

        fn resolveVerificationMode(self: *Self, config: Config) InitError!client_handshake.VerificationMode {
            if (config.verification) |verification| return verification;
            if (config.insecure_skip_verify) return .no_verification;
            if (config.root_cas) |bundle| return .{ .bundle = bundle };

            self.owned_root_cas = .{};
            if (self.owned_root_cas) |*bundle| try bundle.rescan(self.allocator);
            return .{ .bundle = &self.owned_root_cas.? };
        }
    };
}

test "tls client conn type-erases and writes application data" {
    const std = @import("std");
    const ConnType = Conn(std);
    const C = @import("common.zig").Make(std);
    const E = @import("extensions.zig").Make(std);
    const K = @import("kdf.zig").Make(std);
    const R = @import("record.zig").Make(std);
    const CH = @import("client_handshake.zig").Make(std);
    const fixtures = @import("test_fixtures.zig");
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

    const RawConn = struct {
        read_buf: [32768]u8 = undefined,
        read_len: usize = 0,
        read_pos: usize = 0,
        write_buf: [32768]u8 = undefined,
        write_len: usize = 0,

        pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
            if (self.read_pos >= self.read_len) return error.EndOfStream;
            const n = @min(buf.len, self.read_len - self.read_pos);
            @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
            self.read_pos += n;
            return n;
        }

        pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
            @memcpy(self.write_buf[self.write_len..][0..buf.len], buf);
            self.write_len += buf.len;
            return buf.len;
        }

        pub fn close(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
        pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
        pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
    };

    const SinkConn = struct {
        target: *RawConn,

        pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
            return error.EndOfStream;
        }

        pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
            @memcpy(self.target.read_buf[self.target.read_len..][0..buf.len], buf);
            self.target.read_len += buf.len;
            return buf.len;
        }

        pub fn close(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
        pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
        pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
    };

    const Helper = struct {
        fn cipherFromTrafficSecret(secret: [K.MAX_TLS13_SECRET_LEN]u8, suite: C.CipherSuite) !R.CipherState() {
            const profile = suite.tls13Profile() orelse return error.TestUnexpectedResult;
            const key_len = suite.keyLength();
            const traffic_secret = secret[0..profile.secretLength()];
            var iv: [12]u8 = undefined;
            K.hkdfExpandLabelIntoProfile(profile, &iv, traffic_secret, "iv", "");
            var key = [_]u8{0} ** 32;
            if (key_len == 16) {
                K.hkdfExpandLabelIntoProfile(profile, key[0..16], traffic_secret, "key", "");
            } else {
                K.hkdfExpandLabelIntoProfile(profile, key[0..32], traffic_secret, "key", "");
            }
            return R.CipherState().init(suite, key[0..key_len], &iv);
        }

        fn appendServerFlight(raw: *RawConn, hs: *CH.ClientHandshake(NetConn)) !void {
            hs.state = .wait_server_hello;

            var client_hello: [1024]u8 = undefined;
            _ = try hs.encodeClientHello(&client_hello);

            const server_secret = [_]u8{0x42} ** std.crypto.dh.X25519.secret_length;
            const server_public = try std.crypto.dh.X25519.recoverPublicKey(server_secret);

            var ext_buf: [128]u8 = undefined;
            var ext_builder = E.ExtensionBuilder.init(&ext_buf);
            try ext_builder.addSelectedVersion(.tls_1_3);
            try ext_builder.addKeyShareServer(.{
                .group = .x25519,
                .key_exchange = &server_public,
            });
            const ext_data = ext_builder.getData();

            var sink = SinkConn{ .target = raw };
            var plain_records = R.RecordLayer(*SinkConn).init(&sink);
            plain_records.setVersion(.tls_1_2);

            var server_hello: [256]u8 = undefined;
            var pos: usize = C.HandshakeHeader.SIZE;
            std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(C.ProtocolVersion.tls_1_2), .big);
            pos += 2;
            @memset(server_hello[pos..][0..32], 0xAA);
            pos += 32;
            server_hello[pos] = 0;
            pos += 1;
            std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(C.CipherSuite.TLS_AES_128_GCM_SHA256), .big);
            pos += 2;
            server_hello[pos] = 0;
            pos += 1;
            std.mem.writeInt(u16, server_hello[pos..][0..2], @intCast(ext_data.len), .big);
            pos += 2;
            @memcpy(server_hello[pos..][0..ext_data.len], ext_data);
            pos += ext_data.len;
            const server_hello_header: C.HandshakeHeader = .{
                .msg_type = .server_hello,
                .length = @intCast(pos - C.HandshakeHeader.SIZE),
            };
            try server_hello_header.serialize(server_hello[0..C.HandshakeHeader.SIZE]);

            var record_buf: [C.MAX_CIPHERTEXT_LEN_TLS12]u8 = undefined;
            _ = try plain_records.writeRecord(.handshake, server_hello[0..pos], &record_buf);
            try hs.processHandshake(server_hello[0..pos]);

            var encrypted_records = R.RecordLayer(*SinkConn).init(&sink);
            encrypted_records.setVersion(.tls_1_3);
            encrypted_records.setWriteCipher(try cipherFromTrafficSecret(hs.server_handshake_traffic_secret, hs.cipher_suite));

            var encrypted_extensions = [_]u8{
                @intFromEnum(C.HandshakeType.encrypted_extensions),
                0x00,
                0x00,
                0x02,
                0x00,
                0x00,
            };
            _ = try encrypted_records.writeRecord(.handshake, &encrypted_extensions, &record_buf);
            try hs.processHandshake(&encrypted_extensions);

            var certificate_msg: [4 + 1 + 3 + 3 + fixtures.self_signed_cert_der.len + 2]u8 = undefined;
            var cert_pos: usize = 4;
            certificate_msg[cert_pos] = 0;
            cert_pos += 1;
            std.mem.writeInt(u24, certificate_msg[cert_pos..][0..3], 3 + fixtures.self_signed_cert_der.len + 2, .big);
            cert_pos += 3;
            std.mem.writeInt(u24, certificate_msg[cert_pos..][0..3], fixtures.self_signed_cert_der.len, .big);
            cert_pos += 3;
            @memcpy(certificate_msg[cert_pos..][0..fixtures.self_signed_cert_der.len], fixtures.self_signed_cert_der[0..]);
            cert_pos += fixtures.self_signed_cert_der.len;
            std.mem.writeInt(u16, certificate_msg[cert_pos..][0..2], 0, .big);
            cert_pos += 2;
            const certificate_header: C.HandshakeHeader = .{
                .msg_type = .certificate,
                .length = @intCast(cert_pos - 4),
            };
            try certificate_header.serialize(certificate_msg[0..4]);
            _ = try encrypted_records.writeRecord(.handshake, certificate_msg[0..cert_pos], &record_buf);
            try hs.processHandshake(certificate_msg[0..cert_pos]);

            const context_string = "TLS 1.3, server CertificateVerify";
            const transcript_before_cert_verify = hs.transcript_hash.peekSha256();
            var cert_verify_input: [64 + context_string.len + 1 + transcript_before_cert_verify.len]u8 = undefined;
            @memset(cert_verify_input[0..64], 0x20);
            @memcpy(cert_verify_input[64..][0..context_string.len], context_string);
            cert_verify_input[64 + context_string.len] = 0;
            @memcpy(cert_verify_input[64 + context_string.len + 1 ..][0..transcript_before_cert_verify.len], transcript_before_cert_verify[0..]);

            const sk = try Ecdsa.SecretKey.fromBytes(fixtures.self_signed_key_scalar);
            const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
            const sig = try kp.sign(cert_verify_input[0..], null);
            var sig_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
            const sig_der = sig.toDer(&sig_der_buf);

            var cert_verify_msg: [4 + 2 + 2 + Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
            var cv_pos: usize = 4;
            std.mem.writeInt(u16, cert_verify_msg[cv_pos..][0..2], @intFromEnum(C.SignatureScheme.ecdsa_secp256r1_sha256), .big);
            cv_pos += 2;
            std.mem.writeInt(u16, cert_verify_msg[cv_pos..][0..2], @intCast(sig_der.len), .big);
            cv_pos += 2;
            @memcpy(cert_verify_msg[cv_pos..][0..sig_der.len], sig_der);
            cv_pos += sig_der.len;
            const cert_verify_header: C.HandshakeHeader = .{
                .msg_type = .certificate_verify,
                .length = @intCast(cv_pos - 4),
            };
            try cert_verify_header.serialize(cert_verify_msg[0..4]);
            _ = try encrypted_records.writeRecord(.handshake, cert_verify_msg[0..cv_pos], &record_buf);
            try hs.processHandshake(cert_verify_msg[0..cv_pos]);

            const finished_key = std.crypto.tls.hkdfExpandLabel(
                std.crypto.kdf.hkdf.HkdfSha256,
                hs.server_handshake_traffic_secret[0..std.crypto.auth.hmac.sha2.HmacSha256.key_length].*,
                "finished",
                "",
                std.crypto.auth.hmac.sha2.HmacSha256.key_length,
            );
            const transcript_before_server_finished = hs.transcript_hash.peekSha256();
            const expected_server_verify_data = std.crypto.tls.hmac(
                std.crypto.auth.hmac.sha2.HmacSha256,
                &transcript_before_server_finished,
                finished_key,
            );

            var server_finished: [4 + expected_server_verify_data.len]u8 = undefined;
            const server_finished_header: C.HandshakeHeader = .{
                .msg_type = .finished,
                .length = expected_server_verify_data.len,
            };
            try server_finished_header.serialize(server_finished[0..4]);
            @memcpy(server_finished[4..], &expected_server_verify_data);
            _ = try encrypted_records.writeRecord(.handshake, &server_finished, &record_buf);
        }
    };

    var raw = RawConn{};
    var conn = try ConnType.init(std.testing.allocator, NetConn.init(&raw), .{
        .server_name = "example.com",
        .verification = .hostname_only,
    });
    defer conn.deinit();

    const typed_before = try conn.as(ConnType);
    var flight_hs = typed_before.handshake_state;
    try Helper.appendServerFlight(&raw, &flight_hs);

    const n = try conn.write("ping");
    try std.testing.expectEqual(@as(usize, 4), n);

    const typed = try conn.as(ConnType);
    try std.testing.expect(typed.handshake_complete);
    try std.testing.expectEqual(CH.HandshakeState.connected, typed.handshake_state.state);
    try std.testing.expect(raw.write_len > 0);
}

test "tls config accepts tls12-only client range" {
    const std = @import("std");
    const ConnType = Conn(std);

    const RawConn = struct {
        pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
            return error.EndOfStream;
        }

        pub fn write(_: *@This(), buf: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
            return buf.len;
        }

        pub fn close(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
        pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
        pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
    };

    var raw = RawConn{};
    var conn = try ConnType.init(std.testing.allocator, NetConn.init(&raw), .{
        .server_name = "example.com",
        .insecure_skip_verify = true,
        .min_version = .tls_1_2,
        .max_version = .tls_1_2,
    });
    defer conn.deinit();
}
