const testing_api = @import("testing");

pub fn make(comptime lib: type) type {
    const common = @import("common.zig").make(lib);
    const extensions = @import("extensions.zig").make(lib);
    const kdf = @import("kdf.zig").make(lib);
    const record = @import("record.zig").make(lib);
    const crypto = lib.crypto;
    const mem = lib.mem;

    return struct {
        pub const HandshakeError = error{
            BufferTooSmall,
            InvalidHandshake,
            InvalidPrivateKey,
            InvalidPublicKey,
            UnsupportedVersion,
            UnsupportedCipherSuite,
            UnsupportedGroup,
            UnexpectedMessage,
            MissingExtension,
            KeyExchangeFailed,
            RecordIoFailed,
            BadRecordMac,
            InvalidConfig,
            ConnectionRefused,
            ConnectionReset,
            BrokenPipe,
            TimedOut,
        };

        pub const HandshakeState = enum {
            wait_client_hello,
            send_server_flight,
            wait_client_key_exchange,
            wait_client_finished,
            send_server_finished,
            connected,
            error_state,
        };

        pub const PrivateKey = union(enum) {
            ecdsa_p256_sha256: [32]u8,
            ecdsa_p384_sha384: [48]u8,
        };

        pub const Certificate = struct {
            chain: []const []const u8,
            private_key: PrivateKey,
        };

        pub const Config = struct {
            certificates: []const Certificate,
            min_version: common.ProtocolVersion = .tls_1_3,
            max_version: common.ProtocolVersion = .tls_1_3,
            tls13_cipher_suites: []const common.CipherSuite = &common.DEFAULT_TLS13_CIPHER_SUITES,
            alpn_protocols: []const []const u8 = &.{},
        };

        pub const X25519KeyExchange = struct {
            secret_key: [crypto.dh.X25519.secret_length]u8,
            public_key: [crypto.dh.X25519.public_length]u8,
            shared_secret: [crypto.dh.X25519.shared_length]u8,

            const Self = @This();

            pub fn generate() HandshakeError!Self {
                var self: Self = .{
                    .secret_key = undefined,
                    .public_key = undefined,
                    .shared_secret = [_]u8{0} ** crypto.dh.X25519.shared_length,
                };
                crypto.random.bytes(&self.secret_key);
                self.public_key = crypto.dh.X25519.recoverPublicKey(self.secret_key) catch {
                    return error.KeyExchangeFailed;
                };
                return self;
            }

            pub fn computeSharedSecret(self: *Self, peer_public: []const u8) HandshakeError![]const u8 {
                if (peer_public.len != crypto.dh.X25519.public_length) return error.InvalidPublicKey;
                self.shared_secret = crypto.dh.X25519.scalarmult(
                    self.secret_key,
                    peer_public[0..crypto.dh.X25519.public_length].*,
                ) catch {
                    return error.KeyExchangeFailed;
                };
                return self.shared_secret[0..];
            }
        };

        pub fn ServerHandshake(comptime ConnType: type) type {
            return struct {
                state: HandshakeState,
                config: Config,
                version: common.ProtocolVersion,
                cipher_suite: common.CipherSuite,
                selected_signature_scheme: common.SignatureScheme,
                selected_group: common.NamedGroup,
                selected_alpn_protocol: ?[]const u8,
                client_random: [32]u8,
                server_random: [32]u8,
                legacy_session_id: [32]u8,
                legacy_session_id_len: usize,
                key_exchange: X25519KeyExchange,
                tls12_client_cipher: record.CipherState(),
                tls12_server_cipher: record.CipherState(),
                tls12_client_ccs_received: bool,
                tls12_master_secret: [48]u8,
                tls12_expected_client_verify_data: [12]u8,
                transcript_hash: kdf.TranscriptPair,
                handshake_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                master_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                client_handshake_traffic_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                server_handshake_traffic_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                client_application_traffic_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                server_application_traffic_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                records: record.RecordLayer(ConnType),

                const Self = @This();

                pub fn init(conn: ConnType, config: Config) HandshakeError!Self {
                    try validateConfig(config);

                    var self: Self = .{
                        .state = .wait_client_hello,
                        .config = config,
                        .version = .tls_1_3,
                        .cipher_suite = .TLS_AES_128_GCM_SHA256,
                        .selected_signature_scheme = .ecdsa_secp256r1_sha256,
                        .selected_group = .x25519,
                        .selected_alpn_protocol = null,
                        .client_random = [_]u8{0} ** 32,
                        .server_random = undefined,
                        .legacy_session_id = [_]u8{0} ** 32,
                        .legacy_session_id_len = 0,
                        .key_exchange = try X25519KeyExchange.generate(),
                        .tls12_client_cipher = .none,
                        .tls12_server_cipher = .none,
                        .tls12_client_ccs_received = false,
                        .tls12_master_secret = [_]u8{0} ** 48,
                        .tls12_expected_client_verify_data = [_]u8{0} ** 12,
                        .transcript_hash = kdf.TranscriptPair.init(),
                        .handshake_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .master_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .client_handshake_traffic_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .server_handshake_traffic_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .client_application_traffic_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .server_application_traffic_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .records = record.RecordLayer(ConnType).init(conn),
                    };
                    crypto.random.bytes(&self.server_random);
                    self.records.setVersion(.tls_1_2);
                    return self;
                }

                pub fn processHandshake(self: *Self, data: []const u8) HandshakeError!void {
                    var pos: usize = 0;
                    while (pos + common.HandshakeHeader.SIZE <= data.len) {
                        const header = common.HandshakeHeader.parse(data[pos..]) catch return error.InvalidHandshake;
                        const total_len = common.HandshakeHeader.SIZE + @as(usize, header.length);
                        if (pos + total_len > data.len) return error.InvalidHandshake;

                        const payload = data[pos + common.HandshakeHeader.SIZE ..][0..header.length];
                        const raw = data[pos..][0..total_len];

                        switch (header.msg_type) {
                            .client_hello => {
                                self.transcript_hash.update(raw);
                                try self.processClientHello(payload);
                            },
                            .client_key_exchange => {
                                try self.processClientKeyExchange(payload);
                                self.transcript_hash.update(raw);
                                self.tls12_expected_client_verify_data = self.tls12ClientFinishedVerifyData();
                            },
                            .finished => try self.processClientFinished(payload, raw),
                            else => return error.UnexpectedMessage,
                        }
                        pos += total_len;
                    }
                }

                pub fn processChangeCipherSpec(self: *Self, data: []const u8) HandshakeError!void {
                    if (data.len != 1 or data[0] != @intFromEnum(common.ChangeCipherSpecType.change_cipher_spec)) {
                        return error.InvalidHandshake;
                    }
                    if (self.version == .tls_1_2) {
                        if (self.state != .wait_client_finished) return error.UnexpectedMessage;
                        self.records.setReadCipher(self.tls12_client_cipher);
                        self.tls12_client_ccs_received = true;
                    }
                }

                pub fn shouldSendServerFlight(self: *const Self) bool {
                    return self.state == .send_server_flight or self.state == .send_server_finished;
                }

                pub fn sendServerFlight(self: *Self, handshake_buf: []u8, record_buf: []u8) HandshakeError!void {
                    switch (self.state) {
                        .send_server_flight => {},
                        .send_server_finished => {
                            try self.sendTls12ServerFinished(handshake_buf, record_buf);
                            return;
                        },
                        else => return error.UnexpectedMessage,
                    }

                    self.records.setVersion(.tls_1_2);

                    const server_hello_len = try self.encodeServerHello(handshake_buf);
                    _ = self.records.writeRecord(.handshake, handshake_buf[0..server_hello_len], record_buf, handshake_buf) catch |err| {
                        return mapWriteRecordError(err);
                    };
                    self.transcript_hash.update(handshake_buf[0..server_hello_len]);

                    if (self.version == .tls_1_3) {
                        const ccs = [_]u8{@intFromEnum(common.ChangeCipherSpecType.change_cipher_spec)};
                        _ = self.records.writeRecord(.change_cipher_spec, &ccs, record_buf, handshake_buf) catch |err| {
                            return mapWriteRecordError(err);
                        };

                        try self.deriveHandshakeKeys();
                        try self.setReadCipherFromTrafficSecret(try self.tls13Secret(&self.client_handshake_traffic_secret));
                        try self.setWriteCipherFromTrafficSecret(try self.tls13Secret(&self.server_handshake_traffic_secret));

                        const encrypted_messages = [_]common.HandshakeType{
                            .encrypted_extensions,
                            .certificate,
                            .certificate_verify,
                            .finished,
                        };
                        for (encrypted_messages) |msg_type| {
                            const len = switch (msg_type) {
                                .encrypted_extensions => try self.encodeEncryptedExtensions(handshake_buf),
                                .certificate => try self.encodeCertificate(handshake_buf),
                                .certificate_verify => try self.encodeCertificateVerify(handshake_buf),
                                .finished => try self.encodeFinished(handshake_buf),
                                else => unreachable,
                            };
                            _ = self.records.writeRecord(.handshake, handshake_buf[0..len], record_buf, handshake_buf) catch |err| {
                                return mapWriteRecordError(err);
                            };
                            self.transcript_hash.update(handshake_buf[0..len]);
                            if (msg_type == .finished) {
                                try self.deriveApplicationKeys();
                                try self.setWriteCipherFromTrafficSecret(try self.tls13Secret(&self.server_application_traffic_secret));
                            }
                        }
                        self.state = .wait_client_finished;
                        return;
                    }

                    const certificate_len = try self.encodeCertificate(handshake_buf);
                    _ = self.records.writeRecord(.handshake, handshake_buf[0..certificate_len], record_buf, handshake_buf) catch |err| {
                        return mapWriteRecordError(err);
                    };
                    self.transcript_hash.update(handshake_buf[0..certificate_len]);

                    const server_key_exchange_len = try self.encodeServerKeyExchange(handshake_buf);
                    _ = self.records.writeRecord(.handshake, handshake_buf[0..server_key_exchange_len], record_buf, handshake_buf) catch |err| {
                        return mapWriteRecordError(err);
                    };
                    self.transcript_hash.update(handshake_buf[0..server_key_exchange_len]);

                    const server_hello_done_len = try self.encodeServerHelloDone(handshake_buf);
                    _ = self.records.writeRecord(.handshake, handshake_buf[0..server_hello_done_len], record_buf, handshake_buf) catch |err| {
                        return mapWriteRecordError(err);
                    };
                    self.transcript_hash.update(handshake_buf[0..server_hello_done_len]);
                    self.state = .wait_client_key_exchange;
                }

                fn processClientHello(self: *Self, data: []const u8) HandshakeError!void {
                    if (self.state != .wait_client_hello) return error.UnexpectedMessage;
                    if (data.len < 2 + 32 + 1 + 2 + 1 + 2) return error.InvalidHandshake;

                    const legacy_version: common.ProtocolVersion = @enumFromInt(mem.readInt(u16, data[0..2], .big));
                    if (legacy_version != .tls_1_2) return error.UnsupportedVersion;

                    @memcpy(&self.client_random, data[2..34]);

                    var pos: usize = 34;
                    const session_id_len = data[pos];
                    pos += 1;
                    if (session_id_len > self.legacy_session_id.len) return error.InvalidHandshake;
                    if (pos + session_id_len + 2 > data.len) return error.InvalidHandshake;
                    self.legacy_session_id_len = session_id_len;
                    @memcpy(self.legacy_session_id[0..session_id_len], data[pos..][0..session_id_len]);
                    pos += session_id_len;

                    const cipher_suites_len = mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2;
                    if (cipher_suites_len == 0 or (cipher_suites_len & 1) != 0 or pos + cipher_suites_len > data.len) {
                        return error.InvalidHandshake;
                    }
                    const cipher_suites = data[pos..][0..cipher_suites_len];
                    pos += cipher_suites_len;

                    const compression_methods_len = data[pos];
                    pos += 1;
                    if (compression_methods_len == 0 or pos + compression_methods_len + 2 > data.len) {
                        return error.InvalidHandshake;
                    }
                    var saw_null_compression = false;
                    for (data[pos .. pos + compression_methods_len]) |method| {
                        if (method == @intFromEnum(common.CompressionMethod.null)) saw_null_compression = true;
                    }
                    if (!saw_null_compression) return error.InvalidHandshake;
                    pos += compression_methods_len;

                    const extensions_len = mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2;
                    if (pos + extensions_len != data.len) return error.InvalidHandshake;

                    var supports_tls13 = false;
                    var supports_tls12 = legacy_version == .tls_1_2 and self.versionAllowed(.tls_1_2);
                    var saw_signature_algorithms = false;
                    var saw_key_share = false;
                    var client_key_share: ?[]const u8 = null;
                    var supports_x25519 = false;
                    var seen_exts = [_]u8{0} ** 8192;
                    var ext_pos: usize = pos;
                    const ext_end = pos + extensions_len;
                    while (ext_pos + 4 <= ext_end) {
                        const ext_type: common.ExtensionType = @enumFromInt(mem.readInt(u16, data[ext_pos..][0..2], .big));
                        ext_pos += 2;
                        const ext_len = mem.readInt(u16, data[ext_pos..][0..2], .big);
                        ext_pos += 2;
                        if (ext_pos + ext_len > ext_end) return error.InvalidHandshake;

                        const payload = data[ext_pos..][0..ext_len];
                        ext_pos += ext_len;
                        if (!markExtensionSeen(&seen_exts, ext_type)) return error.InvalidHandshake;

                        switch (ext_type) {
                            .supported_versions => {
                                const versions = try self.parseSupportedVersions(payload);
                                supports_tls13 = versions.tls13;
                                supports_tls12 = versions.tls12;
                            },
                            .signature_algorithms => {
                                self.selected_signature_scheme = try self.chooseSignatureScheme(payload);
                                saw_signature_algorithms = true;
                            },
                            .key_share => {
                                saw_key_share = true;
                                client_key_share = try self.chooseClientKeyShare(payload);
                            },
                            .supported_groups => {
                                supports_x25519 = try self.clientSupportsGroup(payload, .x25519);
                            },
                            .application_layer_protocol_negotiation => {
                                self.selected_alpn_protocol = extensions.findMatchingAlpn(payload, self.config.alpn_protocols) catch {
                                    return error.InvalidHandshake;
                                };
                            },
                            else => {},
                        }
                    }
                    if (ext_pos != ext_end) return error.InvalidHandshake;

                    if (!saw_signature_algorithms) return error.MissingExtension;

                    if (supports_tls13) {
                        if (!saw_key_share) return error.MissingExtension;
                        if (client_key_share == null) return error.UnsupportedGroup;
                        self.version = .tls_1_3;
                        self.cipher_suite = chooseTls13CipherSuite(cipher_suites, self.config.tls13_cipher_suites) orelse return error.UnsupportedCipherSuite;
                        self.selected_group = .x25519;
                        _ = try self.key_exchange.computeSharedSecret(client_key_share.?);
                        self.state = .send_server_flight;
                        return;
                    }

                    if (!supports_tls12) return error.UnsupportedVersion;
                    if (!supports_x25519) return error.UnsupportedGroup;
                    self.version = .tls_1_2;
                    self.applyTls12DowngradeMarker();
                    self.cipher_suite = chooseTls12CipherSuite(cipher_suites) orelse return error.UnsupportedCipherSuite;
                    self.selected_group = .x25519;
                    self.state = .send_server_flight;
                }

                fn processClientFinished(self: *Self, data: []const u8, raw_msg: []const u8) HandshakeError!void {
                    if (self.state != .wait_client_finished) return error.UnexpectedMessage;
                    if (self.version == .tls_1_2) {
                        if (!self.tls12_client_ccs_received) return error.UnexpectedMessage;
                        if (data.len != self.tls12_expected_client_verify_data.len) return error.InvalidHandshake;
                        if (!mem.eql(u8, data, &self.tls12_expected_client_verify_data)) return error.BadRecordMac;
                        self.transcript_hash.update(raw_msg);
                        self.state = .send_server_finished;
                        return;
                    }

                    var expected_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const expected = try self.clientFinishedVerifyData(&expected_buf);
                    if (data.len != expected.len) return error.InvalidHandshake;
                    if (!mem.eql(u8, data, expected)) return error.BadRecordMac;

                    self.transcript_hash.update(raw_msg);
                    try self.setReadCipherFromTrafficSecret(try self.tls13Secret(&self.client_application_traffic_secret));
                    self.state = .connected;
                }

                fn processClientKeyExchange(self: *Self, data: []const u8) HandshakeError!void {
                    if (self.version != .tls_1_2) return error.UnexpectedMessage;
                    if (self.state != .wait_client_key_exchange) return error.UnexpectedMessage;
                    if (data.len < 1) return error.InvalidHandshake;

                    const key_len = data[0];
                    if (1 + key_len != data.len) return error.InvalidHandshake;
                    _ = try self.key_exchange.computeSharedSecret(data[1..][0..key_len]);
                    try self.deriveTls12Secrets();
                    self.state = .wait_client_finished;
                }

                fn encodeServerHello(self: *Self, out: []u8) HandshakeError!usize {
                    if (out.len < common.HandshakeHeader.SIZE + 80) return error.BufferTooSmall;

                    var pos: usize = common.HandshakeHeader.SIZE;
                    mem.writeInt(u16, out[pos..][0..2], @intFromEnum(common.ProtocolVersion.tls_1_2), .big);
                    pos += 2;
                    @memcpy(out[pos..][0..self.server_random.len], &self.server_random);
                    pos += self.server_random.len;
                    out[pos] = @intCast(self.legacy_session_id_len);
                    pos += 1;
                    @memcpy(out[pos..][0..self.legacy_session_id_len], self.legacy_session_id[0..self.legacy_session_id_len]);
                    pos += self.legacy_session_id_len;
                    mem.writeInt(u16, out[pos..][0..2], @intFromEnum(self.cipher_suite), .big);
                    pos += 2;
                    out[pos] = @intFromEnum(common.CompressionMethod.null);
                    pos += 1;

                    if (self.version == .tls_1_3) {
                        var ext_builder = @import("extensions.zig").make(lib).ExtensionBuilder.init(out[pos + 2 ..]);
                        ext_builder.addSelectedVersion(.tls_1_3) catch return error.BufferTooSmall;
                        ext_builder.addKeyShareServer(.{
                            .group = .x25519,
                            .key_exchange = self.key_exchange.public_key[0..],
                        }) catch return error.BufferTooSmall;
                        const ext_data = ext_builder.getData();
                        mem.writeInt(u16, out[pos..][0..2], @intCast(ext_data.len), .big);
                        pos += 2 + ext_data.len;
                    } else {
                        mem.writeInt(u16, out[pos..][0..2], 0, .big);
                        pos += 2;
                    }

                    const header: common.HandshakeHeader = .{
                        .msg_type = .server_hello,
                        .length = @intCast(pos - common.HandshakeHeader.SIZE),
                    };
                    try header.serialize(out[0..common.HandshakeHeader.SIZE]);
                    return pos;
                }

                fn encodeEncryptedExtensions(self: *Self, out: []u8) HandshakeError!usize {
                    if (out.len < common.HandshakeHeader.SIZE + 2) return error.BufferTooSmall;
                    var pos: usize = common.HandshakeHeader.SIZE;
                    var builder = extensions.ExtensionBuilder.init(out[pos + 2 ..]);
                    if (self.selected_alpn_protocol) |protocol| {
                        builder.addAlpn(&.{protocol}) catch return error.BufferTooSmall;
                    }
                    const ext_data = builder.getData();
                    mem.writeInt(u16, out[pos..][0..2], @intCast(ext_data.len), .big);
                    pos += 2 + ext_data.len;
                    const header: common.HandshakeHeader = .{
                        .msg_type = .encrypted_extensions,
                        .length = @intCast(pos - common.HandshakeHeader.SIZE),
                    };
                    try header.serialize(out[0..common.HandshakeHeader.SIZE]);
                    return pos;
                }

                fn encodeCertificate(self: *Self, out: []u8) HandshakeError!usize {
                    const cert = self.config.certificates[0];
                    var pos: usize = common.HandshakeHeader.SIZE;
                    if (self.version == .tls_1_3) {
                        if (out.len < pos + 1 + 3) return error.BufferTooSmall;
                        out[pos] = 0;
                        pos += 1;
                    } else if (out.len < pos + 3) {
                        return error.BufferTooSmall;
                    }

                    const cert_entry_extensions_len: usize = if (self.version == .tls_1_3) 2 else 0;
                    var certs_len: usize = 0;
                    for (cert.chain) |der| certs_len += 3 + der.len + cert_entry_extensions_len;
                    mem.writeInt(u24, out[pos..][0..3], @intCast(certs_len), .big);
                    pos += 3;

                    for (cert.chain) |der| {
                        if (pos + 3 + der.len + cert_entry_extensions_len > out.len) return error.BufferTooSmall;
                        mem.writeInt(u24, out[pos..][0..3], @intCast(der.len), .big);
                        pos += 3;
                        @memcpy(out[pos..][0..der.len], der);
                        pos += der.len;
                        if (self.version == .tls_1_3) {
                            out[pos] = 0;
                            out[pos + 1] = 0;
                            pos += 2;
                        }
                    }

                    const header: common.HandshakeHeader = .{
                        .msg_type = .certificate,
                        .length = @intCast(pos - common.HandshakeHeader.SIZE),
                    };
                    try header.serialize(out[0..common.HandshakeHeader.SIZE]);
                    return pos;
                }

                fn encodeServerKeyExchange(self: *Self, out: []u8) HandshakeError!usize {
                    if (self.version != .tls_1_2) return error.UnexpectedMessage;
                    if (out.len < common.HandshakeHeader.SIZE + 1 + 2 + 1 + 32 + 2 + 2 + 72) return error.BufferTooSmall;

                    var pos: usize = common.HandshakeHeader.SIZE;
                    out[pos] = 0x03; // named_curve
                    pos += 1;
                    mem.writeInt(u16, out[pos..][0..2], @intFromEnum(self.selected_group), .big);
                    pos += 2;
                    out[pos] = crypto.dh.X25519.public_length;
                    pos += 1;
                    @memcpy(out[pos..][0..crypto.dh.X25519.public_length], self.key_exchange.public_key[0..]);
                    const params_end = pos + crypto.dh.X25519.public_length;
                    pos = params_end;

                    var signed_message: [32 + 32 + 1 + 2 + 1 + crypto.dh.X25519.public_length]u8 = undefined;
                    var signed_pos: usize = 0;
                    @memcpy(signed_message[signed_pos..][0..self.client_random.len], &self.client_random);
                    signed_pos += self.client_random.len;
                    @memcpy(signed_message[signed_pos..][0..self.server_random.len], &self.server_random);
                    signed_pos += self.server_random.len;
                    @memcpy(signed_message[signed_pos..][0 .. params_end - common.HandshakeHeader.SIZE], out[common.HandshakeHeader.SIZE..params_end]);
                    signed_pos += params_end - common.HandshakeHeader.SIZE;

                    var signature_buf: [128]u8 = undefined;
                    const signature = try self.signCertificateVerify(signed_message[0..signed_pos], &signature_buf);
                    mem.writeInt(u16, out[pos..][0..2], @intFromEnum(self.selected_signature_scheme), .big);
                    pos += 2;
                    mem.writeInt(u16, out[pos..][0..2], @intCast(signature.len), .big);
                    pos += 2;
                    @memcpy(out[pos..][0..signature.len], signature);
                    pos += signature.len;

                    const header: common.HandshakeHeader = .{
                        .msg_type = .server_key_exchange,
                        .length = @intCast(pos - common.HandshakeHeader.SIZE),
                    };
                    try header.serialize(out[0..common.HandshakeHeader.SIZE]);
                    return pos;
                }

                fn encodeServerHelloDone(_: *Self, out: []u8) HandshakeError!usize {
                    if (out.len < common.HandshakeHeader.SIZE) return error.BufferTooSmall;
                    const header: common.HandshakeHeader = .{
                        .msg_type = .server_hello_done,
                        .length = 0,
                    };
                    try header.serialize(out[0..common.HandshakeHeader.SIZE]);
                    return common.HandshakeHeader.SIZE;
                }

                fn encodeCertificateVerify(self: *Self, out: []u8) HandshakeError!usize {
                    var transcript_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const transcript = try self.tls13TranscriptHash(&transcript_buf);
                    const context_string = "TLS 1.3, server CertificateVerify";
                    var content: [64 + context_string.len + 1 + kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    @memset(content[0..64], 0x20);
                    @memcpy(content[64..][0..context_string.len], context_string);
                    content[64 + context_string.len] = 0;
                    @memcpy(content[64 + context_string.len + 1 ..][0..transcript.len], transcript);

                    var signature_buf: [128]u8 = undefined;
                    const signature = try self.signCertificateVerify(
                        content[0 .. 64 + context_string.len + 1 + transcript.len],
                        &signature_buf,
                    );

                    const total_len = common.HandshakeHeader.SIZE + 2 + 2 + signature.len;
                    if (out.len < total_len) return error.BufferTooSmall;

                    const header: common.HandshakeHeader = .{
                        .msg_type = .certificate_verify,
                        .length = @intCast(2 + 2 + signature.len),
                    };
                    try header.serialize(out[0..common.HandshakeHeader.SIZE]);
                    mem.writeInt(u16, out[common.HandshakeHeader.SIZE..][0..2], @intFromEnum(self.selected_signature_scheme), .big);
                    mem.writeInt(u16, out[common.HandshakeHeader.SIZE + 2 ..][0..2], @intCast(signature.len), .big);
                    @memcpy(out[common.HandshakeHeader.SIZE + 4 ..][0..signature.len], signature);
                    return total_len;
                }

                fn encodeFinished(self: *Self, out: []u8) HandshakeError!usize {
                    var verify_data_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const verify_data = try self.serverFinishedVerifyData(&verify_data_buf);
                    const total_len = common.HandshakeHeader.SIZE + verify_data.len;
                    if (out.len < total_len) return error.BufferTooSmall;

                    const header: common.HandshakeHeader = .{
                        .msg_type = .finished,
                        .length = @intCast(verify_data.len),
                    };
                    try header.serialize(out[0..common.HandshakeHeader.SIZE]);
                    @memcpy(out[common.HandshakeHeader.SIZE..][0..verify_data.len], verify_data);
                    return total_len;
                }

                fn requireTls13Supported(self: *const Self, data: []const u8) HandshakeError!void {
                    if (data.len < 1) return error.InvalidHandshake;
                    const list_len = data[0];
                    if (1 + list_len != data.len or (list_len & 1) != 0) return error.InvalidHandshake;

                    var pos: usize = 1;
                    while (pos + 2 <= data.len) : (pos += 2) {
                        const version: common.ProtocolVersion = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                        if (version == .tls_1_3 and self.versionAllowed(version)) return;
                    }
                    return error.UnsupportedVersion;
                }

                fn chooseSignatureScheme(self: *const Self, data: []const u8) HandshakeError!common.SignatureScheme {
                    if (data.len < 2) return error.InvalidHandshake;
                    const list_len = mem.readInt(u16, data[0..2], .big);
                    if (2 + list_len != data.len or (list_len & 1) != 0) return error.InvalidHandshake;

                    const desired = switch (self.config.certificates[0].private_key) {
                        .ecdsa_p256_sha256 => common.SignatureScheme.ecdsa_secp256r1_sha256,
                        .ecdsa_p384_sha384 => common.SignatureScheme.ecdsa_secp384r1_sha384,
                    };

                    var pos: usize = 2;
                    while (pos + 2 <= data.len) : (pos += 2) {
                        const scheme: common.SignatureScheme = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                        if (scheme == desired) return desired;
                    }
                    return error.InvalidHandshake;
                }

                fn chooseClientKeyShare(_: *const Self, data: []const u8) HandshakeError!?[]const u8 {
                    if (data.len < 2) return error.InvalidHandshake;
                    const list_len = mem.readInt(u16, data[0..2], .big);
                    if (2 + list_len != data.len) return error.InvalidHandshake;

                    var pos: usize = 2;
                    while (pos + 4 <= data.len) {
                        const group: common.NamedGroup = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                        pos += 2;
                        const key_len = mem.readInt(u16, data[pos..][0..2], .big);
                        pos += 2;
                        if (pos + key_len > data.len) return error.InvalidHandshake;
                        const key = data[pos..][0..key_len];
                        pos += key_len;

                        if (group == .x25519) return key;
                    }
                    return null;
                }

                fn parseSupportedVersions(
                    self: *const Self,
                    data: []const u8,
                ) HandshakeError!struct { tls13: bool, tls12: bool } {
                    if (data.len < 1) return error.InvalidHandshake;
                    const list_len = data[0];
                    if (1 + list_len != data.len or (list_len & 1) != 0) return error.InvalidHandshake;

                    var tls13 = false;
                    var tls12 = false;
                    var pos: usize = 1;
                    while (pos + 2 <= data.len) : (pos += 2) {
                        const version: common.ProtocolVersion = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                        if (version == .tls_1_3 and self.versionAllowed(.tls_1_3)) tls13 = true;
                        if (version == .tls_1_2 and self.versionAllowed(.tls_1_2)) tls12 = true;
                    }
                    return .{ .tls13 = tls13, .tls12 = tls12 };
                }

                fn clientSupportsGroup(
                    _: *const Self,
                    data: []const u8,
                    wanted: common.NamedGroup,
                ) HandshakeError!bool {
                    if (data.len < 2) return error.InvalidHandshake;
                    const list_len = mem.readInt(u16, data[0..2], .big);
                    if (2 + list_len != data.len or (list_len & 1) != 0) return error.InvalidHandshake;

                    var pos: usize = 2;
                    while (pos + 2 <= data.len) : (pos += 2) {
                        const group: common.NamedGroup = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                        if (group == wanted) return true;
                    }
                    return false;
                }

                fn chooseTls13CipherSuite(
                    encoded: []const u8,
                    preferred: []const common.CipherSuite,
                ) ?common.CipherSuite {
                    for (preferred) |wanted| {
                        var pos: usize = 0;
                        while (pos + 2 <= encoded.len) : (pos += 2) {
                            const suite: common.CipherSuite = @enumFromInt(mem.readInt(u16, encoded[pos..][0..2], .big));
                            if (suite == wanted) return suite;
                        }
                    }
                    return null;
                }

                fn chooseTls12CipherSuite(encoded: []const u8) ?common.CipherSuite {
                    const preferred = [_]common.CipherSuite{
                        .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                        .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                    };

                    for (preferred) |wanted| {
                        var pos: usize = 0;
                        while (pos + 2 <= encoded.len) : (pos += 2) {
                            const suite: common.CipherSuite = @enumFromInt(mem.readInt(u16, encoded[pos..][0..2], .big));
                            if (suite == wanted) return suite;
                        }
                    }

                    var pos: usize = 0;
                    while (pos + 2 <= encoded.len) : (pos += 2) {
                        const suite: common.CipherSuite = @enumFromInt(mem.readInt(u16, encoded[pos..][0..2], .big));
                        if (suite == .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256) return suite;
                    }
                    return null;
                }

                fn deriveHandshakeKeys(self: *Self) HandshakeError!void {
                    const shared_secret = self.key_exchange.shared_secret[0..];
                    const profile = try self.tls13Profile();
                    const zero_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN;
                    var early_secret_buf: [kdf.MAX_TLS13_SECRET_LEN]u8 = undefined;
                    const early_secret = kdf.hkdfExtractProfile(
                        profile,
                        &early_secret_buf,
                        zero_secret[0..profile.secretLength()],
                        zero_secret[0..profile.secretLength()],
                    );

                    var empty_hash_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const empty_hash = kdf.emptyHash(profile, &empty_hash_buf);

                    var derived_buf: [kdf.MAX_TLS13_SECRET_LEN]u8 = undefined;
                    kdf.hkdfExpandLabelIntoProfile(
                        profile,
                        derived_buf[0..profile.secretLength()],
                        early_secret,
                        "derived",
                        empty_hash,
                    );

                    _ = kdf.hkdfExtractProfile(profile, &self.handshake_secret, derived_buf[0..profile.secretLength()], shared_secret);

                    var transcript_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const transcript = try self.tls13TranscriptHash(&transcript_buf);
                    _ = kdf.deriveSecretProfile(
                        profile,
                        &self.client_handshake_traffic_secret,
                        try self.tls13Secret(&self.handshake_secret),
                        "c hs traffic",
                        transcript,
                    );
                    _ = kdf.deriveSecretProfile(
                        profile,
                        &self.server_handshake_traffic_secret,
                        try self.tls13Secret(&self.handshake_secret),
                        "s hs traffic",
                        transcript,
                    );

                    self.records.setVersion(.tls_1_3);
                }

                fn deriveTls12Secrets(self: *Self) HandshakeError!void {
                    const key_len = self.cipher_suite.keyLength();
                    const fixed_iv_len = self.cipher_suite.tls12FixedIvLength();
                    if (key_len == 0 or fixed_iv_len == 0) return error.UnsupportedCipherSuite;

                    var seed: [64]u8 = undefined;
                    @memcpy(seed[0..32], &self.client_random);
                    @memcpy(seed[32..64], &self.server_random);

                    var master_secret: [48]u8 = undefined;
                    kdf.tls12PrfSha256(&master_secret, self.key_exchange.shared_secret[0..], "master secret", &seed);
                    self.tls12_master_secret = master_secret;

                    var key_seed: [64]u8 = undefined;
                    @memcpy(key_seed[0..32], &self.server_random);
                    @memcpy(key_seed[32..64], &self.client_random);

                    var key_block: [88]u8 = undefined;
                    const key_block_len = 2 * key_len + 2 * fixed_iv_len;
                    kdf.tls12PrfSha256(key_block[0..key_block_len], &self.tls12_master_secret, "key expansion", &key_seed);

                    const client_key = key_block[0..key_len];
                    const server_key = key_block[key_len .. 2 * key_len];
                    var client_iv = [_]u8{0} ** 12;
                    var server_iv = [_]u8{0} ** 12;
                    const client_iv_start = 2 * key_len;
                    const server_iv_start = client_iv_start + fixed_iv_len;
                    @memcpy(client_iv[0..fixed_iv_len], key_block[client_iv_start..][0..fixed_iv_len]);
                    @memcpy(server_iv[0..fixed_iv_len], key_block[server_iv_start..][0..fixed_iv_len]);

                    self.tls12_client_cipher = record.CipherState().init(self.cipher_suite, client_key, &client_iv) catch {
                        return error.KeyExchangeFailed;
                    };
                    self.tls12_server_cipher = record.CipherState().init(self.cipher_suite, server_key, &server_iv) catch {
                        return error.KeyExchangeFailed;
                    };
                    self.records.setVersion(.tls_1_2);
                }

                fn deriveApplicationKeys(self: *Self) HandshakeError!void {
                    const profile = try self.tls13Profile();
                    var empty_hash_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const empty_hash = kdf.emptyHash(profile, &empty_hash_buf);

                    var derived_buf: [kdf.MAX_TLS13_SECRET_LEN]u8 = undefined;
                    kdf.hkdfExpandLabelIntoProfile(
                        profile,
                        derived_buf[0..profile.secretLength()],
                        try self.tls13Secret(&self.handshake_secret),
                        "derived",
                        empty_hash,
                    );
                    const zero_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN;
                    _ = kdf.hkdfExtractProfile(
                        profile,
                        &self.master_secret,
                        derived_buf[0..profile.secretLength()],
                        zero_secret[0..profile.secretLength()],
                    );

                    var transcript_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const transcript = try self.tls13TranscriptHash(&transcript_buf);
                    _ = kdf.deriveSecretProfile(
                        profile,
                        &self.client_application_traffic_secret,
                        try self.tls13Secret(&self.master_secret),
                        "c ap traffic",
                        transcript,
                    );
                    _ = kdf.deriveSecretProfile(
                        profile,
                        &self.server_application_traffic_secret,
                        try self.tls13Secret(&self.master_secret),
                        "s ap traffic",
                        transcript,
                    );
                }

                fn setReadCipherFromTrafficSecret(
                    self: *Self,
                    traffic_secret: []const u8,
                ) HandshakeError!void {
                    self.records.setReadCipher(try self.cipherFromTrafficSecret(traffic_secret));
                }

                fn setWriteCipherFromTrafficSecret(
                    self: *Self,
                    traffic_secret: []const u8,
                ) HandshakeError!void {
                    self.records.setWriteCipher(try self.cipherFromTrafficSecret(traffic_secret));
                }

                fn cipherFromTrafficSecret(
                    self: *Self,
                    traffic_secret: []const u8,
                ) HandshakeError!record.CipherState() {
                    const profile = try self.tls13Profile();
                    const key_len = self.cipher_suite.keyLength();
                    if (key_len == 0 or key_len > 32) return error.UnsupportedCipherSuite;

                    var iv: [12]u8 = undefined;
                    kdf.hkdfExpandLabelIntoProfile(profile, &iv, traffic_secret, "iv", "");
                    var key = [_]u8{0} ** 32;
                    kdf.hkdfExpandLabelIntoProfile(profile, key[0..key_len], traffic_secret, "key", "");
                    return record.CipherState().init(self.cipher_suite, key[0..key_len], &iv) catch {
                        return error.KeyExchangeFailed;
                    };
                }

                fn serverFinishedVerifyData(
                    self: *Self,
                    out: *[kdf.MAX_TLS13_DIGEST_LEN]u8,
                ) HandshakeError![]const u8 {
                    var transcript_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const transcript = try self.tls13TranscriptHash(&transcript_buf);
                    return kdf.finishedVerifyDataProfile(
                        try self.tls13Profile(),
                        out,
                        try self.tls13Secret(&self.server_handshake_traffic_secret),
                        transcript,
                    );
                }

                fn clientFinishedVerifyData(
                    self: *Self,
                    out: *[kdf.MAX_TLS13_DIGEST_LEN]u8,
                ) HandshakeError![]const u8 {
                    var transcript_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const transcript = try self.tls13TranscriptHash(&transcript_buf);
                    return kdf.finishedVerifyDataProfile(
                        try self.tls13Profile(),
                        out,
                        try self.tls13Secret(&self.client_handshake_traffic_secret),
                        transcript,
                    );
                }

                fn tls13Profile(self: *const Self) HandshakeError!common.Tls13CipherProfile {
                    return self.cipher_suite.tls13Profile() orelse error.UnsupportedCipherSuite;
                }

                fn tls13Secret(
                    self: *const Self,
                    secret: *const [kdf.MAX_TLS13_SECRET_LEN]u8,
                ) HandshakeError![]const u8 {
                    const profile = try self.tls13Profile();
                    return secret[0..profile.secretLength()];
                }

                fn tls13TranscriptHash(
                    self: *Self,
                    out: *[kdf.MAX_TLS13_DIGEST_LEN]u8,
                ) HandshakeError![]const u8 {
                    const profile = try self.tls13Profile();
                    return self.transcript_hash.peekByHash(profile.hash, out);
                }

                fn tls12ClientFinishedVerifyData(self: *Self) [12]u8 {
                    const transcript = self.transcript_hash.peekSha256();
                    var out: [12]u8 = undefined;
                    kdf.tls12PrfSha256(&out, &self.tls12_master_secret, "client finished", &transcript);
                    return out;
                }

                fn tls12ServerFinishedVerifyData(self: *Self) [12]u8 {
                    const transcript = self.transcript_hash.peekSha256();
                    var out: [12]u8 = undefined;
                    kdf.tls12PrfSha256(&out, &self.tls12_master_secret, "server finished", &transcript);
                    return out;
                }

                fn sendTls12ServerFinished(self: *Self, handshake_buf: []u8, record_buf: []u8) HandshakeError!void {
                    if (self.version != .tls_1_2) return error.UnexpectedMessage;

                    const ccs = [_]u8{@intFromEnum(common.ChangeCipherSpecType.change_cipher_spec)};
                    _ = self.records.writeRecord(.change_cipher_spec, &ccs, record_buf, handshake_buf) catch |err| {
                        return mapWriteRecordError(err);
                    };

                    self.records.setWriteCipher(self.tls12_server_cipher);

                    const verify_data = self.tls12ServerFinishedVerifyData();
                    const total_len = common.HandshakeHeader.SIZE + verify_data.len;
                    if (handshake_buf.len < total_len) return error.BufferTooSmall;

                    const header: common.HandshakeHeader = .{
                        .msg_type = .finished,
                        .length = verify_data.len,
                    };
                    try header.serialize(handshake_buf[0..common.HandshakeHeader.SIZE]);
                    @memcpy(handshake_buf[common.HandshakeHeader.SIZE..][0..verify_data.len], &verify_data);

                    _ = self.records.writeRecord(.handshake, handshake_buf[0..total_len], record_buf, handshake_buf) catch |err| {
                        return mapWriteRecordError(err);
                    };
                    self.transcript_hash.update(handshake_buf[0..total_len]);
                    self.state = .connected;
                }

                fn mapWriteRecordError(err: record.RecordError) HandshakeError {
                    return switch (err) {
                        error.BufferTooSmall,
                        error.RecordTooLarge,
                        => error.BufferTooSmall,

                        error.ConnectionRefused => error.ConnectionRefused,
                        error.ConnectionReset => error.ConnectionReset,
                        error.BrokenPipe => error.BrokenPipe,
                        error.TimedOut => error.TimedOut,

                        else => error.RecordIoFailed,
                    };
                }

                fn signCertificateVerify(
                    self: *const Self,
                    message: []const u8,
                    out: []u8,
                ) HandshakeError![]const u8 {
                    return switch (self.config.certificates[0].private_key) {
                        .ecdsa_p256_sha256 => |scalar| blk: {
                            const Ecdsa = crypto.sign.ecdsa.EcdsaP256Sha256;
                            const sk = Ecdsa.SecretKey.fromBytes(scalar) catch return error.InvalidPrivateKey;
                            const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch return error.InvalidPrivateKey;
                            const sig = kp.sign(message, null) catch return error.InvalidPrivateKey;
                            var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
                            const der = sig.toDer(&der_buf);
                            if (out.len < der.len) return error.BufferTooSmall;
                            @memcpy(out[0..der.len], der);
                            break :blk out[0..der.len];
                        },
                        .ecdsa_p384_sha384 => |scalar| blk: {
                            const Ecdsa = crypto.sign.ecdsa.EcdsaP384Sha384;
                            const sk = Ecdsa.SecretKey.fromBytes(scalar) catch return error.InvalidPrivateKey;
                            const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch return error.InvalidPrivateKey;
                            const sig = kp.sign(message, null) catch return error.InvalidPrivateKey;
                            var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
                            const der = sig.toDer(&der_buf);
                            if (out.len < der.len) return error.BufferTooSmall;
                            @memcpy(out[0..der.len], der);
                            break :blk out[0..der.len];
                        },
                    };
                }

                fn versionAllowed(self: *const Self, version: common.ProtocolVersion) bool {
                    return @intFromEnum(version) >= @intFromEnum(self.config.min_version) and
                        @intFromEnum(version) <= @intFromEnum(self.config.max_version);
                }

                fn applyTls12DowngradeMarker(self: *Self) void {
                    if (self.config.max_version != .tls_1_3) return;
                    @memcpy(self.server_random[24..32], "DOWNGRD\x01");
                }

                pub fn validateConfig(config: Config) HandshakeError!void {
                    if (config.certificates.len == 0) return error.InvalidConfig;
                    if (config.certificates[0].chain.len == 0) return error.InvalidConfig;
                    if (!common.validateTls13CipherSuites(config.tls13_cipher_suites)) return error.UnsupportedCipherSuite;
                    if (@intFromEnum(config.min_version) > @intFromEnum(config.max_version)) return error.InvalidConfig;
                    if ((config.min_version != .tls_1_2 and config.min_version != .tls_1_3) or
                        (config.max_version != .tls_1_2 and config.max_version != .tls_1_3))
                    {
                        return error.UnsupportedVersion;
                    }
                }

                fn markExtensionSeen(seen: *[8192]u8, ext_type: common.ExtensionType) bool {
                    const value: usize = @intFromEnum(ext_type);
                    const byte_index = value / 8;
                    const bit_index: u3 = @intCast(value % 8);
                    const mask: u8 = @as(u8, 1) << bit_index;
                    if ((seen[byte_index] & mask) != 0) return false;
                    seen[byte_index] |= mask;
                    return true;
                }
            };
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const client = @import("client_handshake.zig").make(lib);
            const fixtures = @import("test_fixtures.zig");
            const tls_server = make(lib);
            const tls_common = @import("common.zig").make(lib);

            const MockConn = struct {
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

            const Helpers = struct {
                fn duplicateClientHelloExtension(
                    msg: []const u8,
                    ext_type: tls_common.ExtensionType,
                    out: []u8,
                ) ![]const u8 {
                    var pos: usize = tls_common.HandshakeHeader.SIZE + 2 + 32;
                    const session_id_len = msg[pos];
                    pos += 1 + session_id_len;

                    const cipher_suites_len = lib.mem.readInt(u16, msg[pos..][0..2], .big);
                    pos += 2 + cipher_suites_len;

                    const compression_methods_len = msg[pos];
                    pos += 1 + compression_methods_len;

                    const ext_len_pos = pos;
                    const ext_len = lib.mem.readInt(u16, msg[pos..][0..2], .big);
                    pos += 2;
                    const ext_start = pos;
                    const ext_end = ext_start + ext_len;

                    var scan = ext_start;
                    while (scan + 4 <= ext_end) {
                        const got: tls_common.ExtensionType = @enumFromInt(lib.mem.readInt(u16, msg[scan..][0..2], .big));
                        const got_len = lib.mem.readInt(u16, msg[scan + 2 ..][0..2], .big);
                        const total = 4 + got_len;
                        if (scan + total > ext_end) return error.TestUnexpectedResult;
                        if (got == ext_type) {
                            if (out.len < msg.len + total) return error.TestUnexpectedResult;
                            @memcpy(out[0..ext_end], msg[0..ext_end]);
                            @memcpy(out[ext_end..][0..total], msg[scan..][0..total]);
                            @memcpy(out[ext_end + total ..][0 .. msg.len - ext_end], msg[ext_end..]);
                            lib.mem.writeInt(u16, out[ext_len_pos..][0..2], @intCast(ext_len + total), .big);
                            lib.mem.writeInt(u24, out[1..4], @intCast((msg.len - tls_common.HandshakeHeader.SIZE) + total), .big);
                            return out[0 .. msg.len + total];
                        }
                        scan += total;
                    }

                    return error.TestUnexpectedResult;
                }

                fn removeClientHelloExtension(
                    msg: []const u8,
                    ext_type: tls_common.ExtensionType,
                    out: []u8,
                ) ![]const u8 {
                    var pos: usize = tls_common.HandshakeHeader.SIZE + 2 + 32;
                    const session_id_len = msg[pos];
                    pos += 1 + session_id_len;
                    const cipher_suites_len = lib.mem.readInt(u16, msg[pos..][0..2], .big);
                    pos += 2 + cipher_suites_len;
                    const compression_methods_len = msg[pos];
                    pos += 1 + compression_methods_len;

                    const ext_len_pos = pos;
                    const ext_len = lib.mem.readInt(u16, msg[pos..][0..2], .big);
                    pos += 2;
                    const ext_start = pos;
                    const ext_end = ext_start + ext_len;

                    var scan = ext_start;
                    while (scan + 4 <= ext_end) {
                        const got: tls_common.ExtensionType = @enumFromInt(lib.mem.readInt(u16, msg[scan..][0..2], .big));
                        const got_len = lib.mem.readInt(u16, msg[scan + 2 ..][0..2], .big);
                        const total = 4 + got_len;
                        if (scan + total > ext_end) return error.TestUnexpectedResult;
                        if (got == ext_type) {
                            if (out.len < msg.len - total) return error.TestUnexpectedResult;
                            @memcpy(out[0..scan], msg[0..scan]);
                            @memcpy(out[scan..][0 .. ext_end - (scan + total)], msg[scan + total .. ext_end]);
                            @memcpy(out[scan + (ext_end - (scan + total)) ..][0 .. msg.len - ext_end], msg[ext_end..]);
                            lib.mem.writeInt(u16, out[ext_len_pos..][0..2], @intCast(ext_len - total), .big);
                            lib.mem.writeInt(u24, out[1..4], @intCast((msg.len - tls_common.HandshakeHeader.SIZE) - total), .big);
                            return out[0 .. msg.len - total];
                        }
                        scan += total;
                    }
                    return error.TestUnexpectedResult;
                }
            };

            {
                var client_conn = MockConn{};
                var ch = try client.ClientHandshake(*MockConn).initWithOptions(&client_conn, .{
                    .hostname = "example.com",
                    .allocator = allocator,
                    .verification = .no_verification,
                    .tls13_cipher_suites = &.{
                        .TLS_AES_128_GCM_SHA256,
                        .TLS_AES_256_GCM_SHA384,
                    },
                });
                var hello: [2048]u8 = undefined;
                const hello_len = try ch.encodeClientHello(&hello);

                var server_conn = MockConn{};
                var sh = try tls_server.ServerHandshake(*MockConn).init(&server_conn, .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                    .tls13_cipher_suites = &.{.TLS_AES_256_GCM_SHA384},
                });

                try sh.processHandshake(hello[0..hello_len]);
                try testing.expectEqual(tls_common.ProtocolVersion.tls_1_3, sh.version);
                try testing.expectEqual(tls_common.CipherSuite.TLS_AES_256_GCM_SHA384, sh.cipher_suite);
                try testing.expectEqual(tls_server.HandshakeState.send_server_flight, sh.state);
            }

            {
                var client_conn = MockConn{};
                var ch = try client.ClientHandshake(*MockConn).initWithOptions(&client_conn, .{
                    .hostname = "example.com",
                    .allocator = allocator,
                    .verification = .no_verification,
                });
                var hello: [2048]u8 = undefined;
                const hello_len = try ch.encodeClientHello(&hello);

                var dup_hello: [2304]u8 = undefined;
                const bad_hello = try Helpers.duplicateClientHelloExtension(
                    hello[0..hello_len],
                    .supported_versions,
                    &dup_hello,
                );

                var server_conn = MockConn{};
                var sh = try tls_server.ServerHandshake(*MockConn).init(&server_conn, .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });

                try testing.expectError(error.InvalidHandshake, sh.processHandshake(bad_hello));
            }

            {
                var client_conn = MockConn{};
                var ch = try client.ClientHandshake(*MockConn).initWithOptions(&client_conn, .{
                    .hostname = "example.com",
                    .allocator = allocator,
                    .verification = .no_verification,
                    .min_version = .tls_1_2,
                    .max_version = .tls_1_3,
                });
                var hello: [2048]u8 = undefined;
                const hello_len = try ch.encodeClientHello(&hello);

                var stripped: [2048]u8 = undefined;
                const bad_hello = try Helpers.removeClientHelloExtension(
                    hello[0..hello_len],
                    .key_share,
                    &stripped,
                );

                var server_conn = MockConn{};
                var sh = try tls_server.ServerHandshake(*MockConn).init(&server_conn, .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                    .min_version = .tls_1_2,
                    .max_version = .tls_1_3,
                });

                try testing.expectError(error.MissingExtension, sh.processHandshake(bad_hello));
            }

            {
                var client_conn = MockConn{};
                var ch = try client.ClientHandshake(*MockConn).initWithOptions(&client_conn, .{
                    .hostname = "example.com",
                    .allocator = allocator,
                    .verification = .no_verification,
                    .min_version = .tls_1_2,
                    .max_version = .tls_1_2,
                });
                var hello: [2048]u8 = undefined;
                const hello_len = try ch.encodeClientHello(&hello);

                var server_conn = MockConn{};
                var sh = try tls_server.ServerHandshake(*MockConn).init(&server_conn, .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                    .min_version = .tls_1_2,
                    .max_version = .tls_1_3,
                });

                try sh.processHandshake(hello[0..hello_len]);
                try testing.expectEqual(tls_server.HandshakeState.send_server_flight, sh.state);
                try testing.expectEqual(tls_common.ProtocolVersion.tls_1_2, sh.version);
                try testing.expectEqual(tls_common.CipherSuite.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256, sh.cipher_suite);
                try testing.expectEqualSlices(u8, "DOWNGRD\x01", sh.server_random[24..32]);
            }
        }
    }.run);
}
