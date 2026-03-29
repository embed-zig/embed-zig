pub fn make(comptime lib: type) type {
    const common = @import("common.zig").make(lib);
    const extensions = @import("extensions.zig").make(lib);
    const kdf = @import("kdf.zig").make(lib);
    const record = @import("record.zig").make(lib);
    const crypto = lib.crypto;
    const mem = lib.mem;
    const time = lib.time;
    const Allocator = lib.mem.Allocator;

    return struct {
        pub const HandshakeError = error{
            BufferTooSmall,
            InvalidHandshake,
            InvalidPublicKey,
            UnknownCa,
            UnsupportedVersion,
            UnsupportedCipherSuite,
            UnsupportedGroup,
            UnexpectedMessage,
            MissingExtension,
            KeyExchangeFailed,
            RecordIoFailed,
            BadRecordMac,
        };

        pub const HandshakeState = enum {
            initial,
            wait_server_hello,
            wait_encrypted_extensions,
            wait_certificate,
            wait_server_key_exchange,
            wait_certificate_verify,
            wait_server_hello_done,
            wait_finished,
            connected,
            error_state,
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

            pub fn publicKey(self: *const Self) []const u8 {
                return self.public_key[0..];
            }

            pub fn computeSharedSecret(self: *Self, peer_public: []const u8) HandshakeError![]const u8 {
                if (peer_public.len != crypto.dh.X25519.public_length) return error.InvalidPublicKey;
                self.shared_secret = crypto.dh.X25519.scalarmult(self.secret_key, peer_public[0..crypto.dh.X25519.public_length].*) catch {
                    return error.KeyExchangeFailed;
                };
                return self.shared_secret[0..];
            }
        };

        pub const KeyExchange = union(enum) {
            x25519: X25519KeyExchange,

            const Self = @This();

            pub fn generate(named_group: common.NamedGroup) HandshakeError!Self {
                return switch (named_group) {
                    .x25519 => .{ .x25519 = try X25519KeyExchange.generate() },
                    else => error.UnsupportedGroup,
                };
            }

            pub fn group(self: Self) common.NamedGroup {
                return switch (self) {
                    .x25519 => .x25519,
                };
            }

            pub fn publicKey(self: *const Self) []const u8 {
                return switch (self.*) {
                    .x25519 => |*kx| kx.publicKey(),
                };
            }

            pub fn computeSharedSecret(self: *Self, peer_public: []const u8) HandshakeError![]const u8 {
                return switch (self.*) {
                    .x25519 => |*kx| try kx.computeSharedSecret(peer_public),
                };
            }
        };

        pub const VerificationMode = union(enum) {
            no_verification,
            hostname_only,
            self_signed,
            bundle: *const crypto.Certificate.Bundle,
        };

        pub const InitOptions = struct {
            hostname: []const u8,
            allocator: Allocator,
            verification: VerificationMode,
            min_version: common.ProtocolVersion = .tls_1_2,
            max_version: common.ProtocolVersion = .tls_1_3,
            tls12_cipher_suites: []const common.CipherSuite = &common.DEFAULT_TLS12_CIPHER_SUITES,
            tls13_cipher_suites: []const common.CipherSuite = &common.DEFAULT_TLS13_CIPHER_SUITES,
        };

        pub fn ClientHandshake(comptime ConnType: type) type {
            return struct {
                state: HandshakeState,
                version: common.ProtocolVersion,
                cipher_suite: common.CipherSuite,
                hostname: []const u8,
                allocator: Allocator,
                verification: VerificationMode,
                min_version: common.ProtocolVersion,
                max_version: common.ProtocolVersion,
                tls12_cipher_suites: []const common.CipherSuite,
                tls13_cipher_suites: []const common.CipherSuite,
                client_random: [32]u8,
                legacy_session_id: [32]u8,
                server_random: [32]u8,
                key_exchange: KeyExchange,
                tls12_secp256r1_keypair: crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair,
                tls12_secp384r1_keypair: crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair,
                tls12_negotiated_group: ?common.NamedGroup,
                tls12_shared_secret: [48]u8,
                tls12_shared_secret_len: usize,
                tls12_master_secret: [48]u8,
                tls12_client_cipher: record.CipherState(),
                tls12_server_cipher: record.CipherState(),
                tls12_expected_server_verify_data: [12]u8,
                tls12_client_flight_sent: bool,
                tls12_server_ccs_received: bool,
                transcript_hash: kdf.TranscriptPair,
                handshake_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                master_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                client_handshake_traffic_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                server_handshake_traffic_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                client_application_traffic_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                server_application_traffic_secret: [kdf.MAX_TLS13_SECRET_LEN]u8,
                server_finished_received: bool,
                server_cert_der: [4096]u8,
                server_cert_der_len: usize,
                records: record.RecordLayer(ConnType),

                const Self = @This();

                pub fn init(
                    conn: ConnType,
                    hostname: []const u8,
                    allocator: Allocator,
                    skip_verify: bool,
                ) HandshakeError!Self {
                    return initWithOptions(conn, .{
                        .hostname = hostname,
                        .allocator = allocator,
                        .verification = if (skip_verify) .no_verification else .hostname_only,
                    });
                }

                pub fn initWithOptions(
                    conn: ConnType,
                    options: InitOptions,
                ) HandshakeError!Self {
                    try validateVersionRange(options.min_version, options.max_version);
                    if (!common.validateTls12CipherSuites(options.tls12_cipher_suites)) return error.UnsupportedCipherSuite;
                    if (!common.validateTls13CipherSuites(options.tls13_cipher_suites)) return error.UnsupportedCipherSuite;

                    var self: Self = .{
                        .state = .initial,
                        .version = .tls_1_3,
                        .cipher_suite = if (options.max_version == .tls_1_2)
                            options.tls12_cipher_suites[0]
                        else
                            options.tls13_cipher_suites[0],
                        .hostname = options.hostname,
                        .allocator = options.allocator,
                        .verification = options.verification,
                        .min_version = options.min_version,
                        .max_version = options.max_version,
                        .tls12_cipher_suites = options.tls12_cipher_suites,
                        .tls13_cipher_suites = options.tls13_cipher_suites,
                        .client_random = undefined,
                        .legacy_session_id = undefined,
                        .server_random = [_]u8{0} ** 32,
                        .key_exchange = try KeyExchange.generate(.x25519),
                        .tls12_secp256r1_keypair = try generateP256KeyPair(),
                        .tls12_secp384r1_keypair = try generateP384KeyPair(),
                        .tls12_negotiated_group = null,
                        .tls12_shared_secret = [_]u8{0} ** 48,
                        .tls12_shared_secret_len = 0,
                        .tls12_master_secret = [_]u8{0} ** 48,
                        .tls12_client_cipher = .none,
                        .tls12_server_cipher = .none,
                        .tls12_expected_server_verify_data = [_]u8{0} ** 12,
                        .tls12_client_flight_sent = false,
                        .tls12_server_ccs_received = false,
                        .transcript_hash = kdf.TranscriptPair.init(),
                        .handshake_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .master_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .client_handshake_traffic_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .server_handshake_traffic_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .client_application_traffic_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .server_application_traffic_secret = [_]u8{0} ** kdf.MAX_TLS13_SECRET_LEN,
                        .server_finished_received = false,
                        .server_cert_der = undefined,
                        .server_cert_der_len = 0,
                        .records = record.RecordLayer(ConnType).init(conn),
                    };
                    crypto.random.bytes(&self.client_random);
                    crypto.random.bytes(&self.legacy_session_id);
                    self.records.setVersion(.tls_1_0);
                    return self;
                }

                fn validateVersionRange(
                    min_version: common.ProtocolVersion,
                    max_version: common.ProtocolVersion,
                ) HandshakeError!void {
                    if ((min_version != .tls_1_2 and min_version != .tls_1_3) or
                        (max_version != .tls_1_2 and max_version != .tls_1_3))
                    {
                        return error.UnsupportedVersion;
                    }
                    if (@intFromEnum(min_version) > @intFromEnum(max_version)) return error.UnsupportedVersion;
                }

                pub fn sendClientHello(self: *Self, handshake_buf: []u8, record_buf: []u8) HandshakeError!usize {
                    const len = try self.encodeClientHello(handshake_buf);
                    _ = self.records.writeRecord(.handshake, handshake_buf[0..len], record_buf, handshake_buf) catch {
                        return error.RecordIoFailed;
                    };
                    self.state = .wait_server_hello;
                    return len;
                }

                pub fn encodeClientHello(self: *Self, out: []u8) HandshakeError!usize {
                    if (out.len < common.HandshakeHeader.SIZE + 64) return error.BufferTooSmall;

                    var body_pos: usize = common.HandshakeHeader.SIZE;
                    mem.writeInt(u16, out[body_pos..][0..2], @intFromEnum(common.ProtocolVersion.tls_1_2), .big);
                    body_pos += 2;

                    @memcpy(out[body_pos..][0..self.client_random.len], &self.client_random);
                    body_pos += self.client_random.len;

                    out[body_pos] = self.legacy_session_id.len;
                    body_pos += 1;
                    @memcpy(out[body_pos..][0..self.legacy_session_id.len], &self.legacy_session_id);
                    body_pos += self.legacy_session_id.len;

                    const offer_tls13 = self.offeredTls13();
                    const offer_tls12 = self.versionAllowed(.tls_1_2);
                    const tls13_cipher_suite_count: usize = if (offer_tls13) self.tls13_cipher_suites.len else 0;
                    const tls12_cipher_suite_count: usize = if (offer_tls12) self.tls12_cipher_suites.len else 0;
                    const cipher_suite_count = tls13_cipher_suite_count + tls12_cipher_suite_count;
                    mem.writeInt(u16, out[body_pos..][0..2], @intCast(cipher_suite_count * 2), .big);
                    body_pos += 2;
                    if (offer_tls13) {
                        for (self.tls13_cipher_suites) |suite| {
                            mem.writeInt(u16, out[body_pos..][0..2], @intFromEnum(suite), .big);
                            body_pos += 2;
                        }
                    }
                    if (offer_tls12) {
                        for (self.tls12_cipher_suites) |suite| {
                            mem.writeInt(u16, out[body_pos..][0..2], @intFromEnum(suite), .big);
                            body_pos += 2;
                        }
                    }

                    out[body_pos] = 1;
                    body_pos += 1;
                    out[body_pos] = @intFromEnum(common.CompressionMethod.null);
                    body_pos += 1;

                    var supported_versions: [2]common.ProtocolVersion = .{ .tls_1_3, .tls_1_2 };
                    const supported_versions_len: usize = switch (self.max_version) {
                        .tls_1_2 => blk: {
                            supported_versions[0] = .tls_1_2;
                            break :blk 1;
                        },
                        .tls_1_3 => if (self.min_version == .tls_1_3) 1 else 2,
                        else => return error.UnsupportedVersion,
                    };
                    var ext_builder = extensions.ExtensionBuilder.init(out[body_pos + 2 ..]);
                    ext_builder.addServerName(self.hostname) catch |err| return mapExtensionError(err);
                    ext_builder.addSupportedVersions(supported_versions[0..supported_versions_len]) catch |err| return mapExtensionError(err);
                    var supported_groups: [4]common.NamedGroup = .{ .x25519, .secp256r1, .secp384r1, .x25519 };
                    const supported_groups_len: usize = if (self.max_version == .tls_1_2) blk: {
                        supported_groups = .{ .x25519_mlkem768, .secp256r1, .secp384r1, .x25519 };
                        break :blk 4;
                    } else 3;
                    ext_builder.addSupportedGroups(supported_groups[0..supported_groups_len]) catch |err| return mapExtensionError(err);
                    ext_builder.addEcPointFormats() catch |err| return mapExtensionError(err);
                    ext_builder.addSignatureAlgorithms(&.{
                        .ecdsa_secp256r1_sha256,
                        .ecdsa_secp384r1_sha384,
                        .rsa_pkcs1_sha256,
                        .rsa_pkcs1_sha384,
                        .rsa_pkcs1_sha512,
                        .rsa_pss_rsae_sha256,
                        .rsa_pss_rsae_sha384,
                        .rsa_pss_rsae_sha512,
                        .rsa_pss_pss_sha256,
                        .rsa_pss_pss_sha384,
                        .rsa_pss_pss_sha512,
                        .rsa_pkcs1_sha1,
                        .ed25519,
                    }) catch |err| return mapExtensionError(err);
                    ext_builder.addKeyShareClient(&.{.{
                        .group = self.key_exchange.group(),
                        .key_exchange = self.key_exchange.publicKey(),
                    }}) catch |err| return mapExtensionError(err);
                    ext_builder.addPskKeyExchangeModes(&.{.psk_dhe_ke}) catch |err| return mapExtensionError(err);

                    const ext_data = ext_builder.getData();
                    mem.writeInt(u16, out[body_pos..][0..2], @intCast(ext_data.len), .big);
                    body_pos += 2 + ext_data.len;

                    const payload_len = body_pos - common.HandshakeHeader.SIZE;
                    const header: common.HandshakeHeader = .{
                        .msg_type = .client_hello,
                        .length = @intCast(payload_len),
                    };
                    try header.serialize(out[0..common.HandshakeHeader.SIZE]);

                    self.transcript_hash.update(out[0..body_pos]);
                    return body_pos;
                }

                pub fn processRecord(self: *Self, record_buf: []u8, plaintext_buf: []u8) HandshakeError!void {
                    const res = self.records.readRecord(record_buf, plaintext_buf) catch return error.RecordIoFailed;
                    if (res.content_type != .handshake) return error.UnexpectedMessage;
                    try self.processHandshake(plaintext_buf[0..res.length]);
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
                            .server_hello => {
                                self.transcript_hash.update(raw);
                                try self.processServerHello(payload);
                            },
                            .encrypted_extensions => {
                                self.transcript_hash.update(raw);
                                try self.processEncryptedExtensions(payload);
                            },
                            .certificate => {
                                self.transcript_hash.update(raw);
                                try self.processCertificate(payload);
                            },
                            .server_key_exchange => {
                                try self.processServerKeyExchange(payload);
                                self.transcript_hash.update(raw);
                            },
                            .server_hello_done => {
                                try self.processServerHelloDone(payload);
                                self.transcript_hash.update(raw);
                            },
                            .certificate_verify => {
                                try self.processCertificateVerify(payload);
                                self.transcript_hash.update(raw);
                            },
                            .finished => {
                                try self.processServerFinished(payload, raw);
                            },
                            else => return error.UnexpectedMessage,
                        }

                        pos += total_len;
                    }
                    if (pos != data.len) return error.InvalidHandshake;
                }

                fn processServerHello(self: *Self, data: []const u8) HandshakeError!void {
                    if (self.state != .wait_server_hello) return error.UnexpectedMessage;
                    if (data.len < 38) return error.InvalidHandshake;

                    const legacy_version: common.ProtocolVersion = @enumFromInt(mem.readInt(u16, data[0..2], .big));
                    if (legacy_version != .tls_1_2) return error.UnsupportedVersion;

                    @memcpy(&self.server_random, data[2..34]);

                    var pos: usize = 34;
                    const session_id_len = data[pos];
                    pos += 1;
                    if (pos + session_id_len + 2 + 1 + 2 > data.len) return error.InvalidHandshake;
                    pos += session_id_len;

                    self.cipher_suite = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                    pos += 2;

                    if (data[pos] != @intFromEnum(common.CompressionMethod.null)) return error.InvalidHandshake;
                    pos += 1;

                    const ext_len = mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2;
                    if (pos + ext_len != data.len) return error.InvalidHandshake;

                    var saw_supported_versions = false;
                    var saw_key_share = false;
                    var tls12_server_hello = false;
                    var seen_exts = [_]u8{0} ** 8192;
                    var ext_pos: usize = pos;
                    const ext_end = pos + ext_len;
                    while (ext_pos + 4 <= ext_end) {
                        const ext_type: common.ExtensionType = @enumFromInt(mem.readInt(u16, data[ext_pos..][0..2], .big));
                        ext_pos += 2;
                        const payload_len = mem.readInt(u16, data[ext_pos..][0..2], .big);
                        ext_pos += 2;
                        if (ext_pos + payload_len > ext_end) return error.InvalidHandshake;

                        const payload = data[ext_pos..][0..payload_len];
                        ext_pos += payload_len;
                        if (!markExtensionSeen(&seen_exts, ext_type)) return error.InvalidHandshake;

                        switch (ext_type) {
                            .supported_versions => {
                                self.version = extensions.parseSupportedVersion(payload) catch return error.InvalidHandshake;
                                if (!self.versionAllowed(self.version)) return error.UnsupportedVersion;
                                if (self.version == .tls_1_2) {
                                    tls12_server_hello = true;
                                } else if (self.version != .tls_1_3) {
                                    return error.UnsupportedVersion;
                                }
                                saw_supported_versions = true;
                            },
                            .key_share => {
                                const entry = extensions.parseKeyShareServer(payload) catch return error.InvalidHandshake;
                                if (entry.group != .x25519) return error.UnsupportedGroup;
                                const shared_secret = try self.key_exchange.computeSharedSecret(entry.key_exchange);
                                try self.deriveHandshakeKeys(shared_secret);
                                saw_key_share = true;
                            },
                            else => {},
                        }
                    }
                    if (ext_pos != ext_end) return error.InvalidHandshake;

                    if (self.cipher_suite.isTls13()) {
                        if (!self.clientSupportsTls13CipherSuite(self.cipher_suite)) return error.UnsupportedCipherSuite;
                        if (!saw_supported_versions or !saw_key_share) return error.MissingExtension;
                        if (self.version != .tls_1_3) return error.UnsupportedVersion;
                        self.state = .wait_encrypted_extensions;
                        return;
                    }

                    if (!self.clientSupportsTls12CipherSuite(self.cipher_suite)) return error.UnsupportedCipherSuite;
                    if (!saw_supported_versions) {
                        if (!self.versionAllowed(.tls_1_2)) return error.UnsupportedVersion;
                        self.version = .tls_1_2;
                    } else if (!tls12_server_hello) {
                        return error.UnsupportedVersion;
                    }
                    if (self.offeredTls13() and self.serverHelloIndicatesDowngrade()) {
                        return error.InvalidHandshake;
                    }
                    self.records.setVersion(.tls_1_2);
                    self.state = .wait_certificate;
                }

                fn versionAllowed(self: Self, version: common.ProtocolVersion) bool {
                    return @intFromEnum(version) >= @intFromEnum(self.min_version) and
                        @intFromEnum(version) <= @intFromEnum(self.max_version);
                }

                fn clientSupportsTls13CipherSuite(self: *const Self, suite: common.CipherSuite) bool {
                    for (self.tls13_cipher_suites) |allowed| {
                        if (allowed == suite) return true;
                    }
                    return false;
                }

                fn clientSupportsTls12CipherSuite(self: *const Self, suite: common.CipherSuite) bool {
                    for (self.tls12_cipher_suites) |allowed| {
                        if (allowed == suite) return true;
                    }
                    return false;
                }

                fn offeredTls13(self: *const Self) bool {
                    return self.max_version == .tls_1_3;
                }

                fn serverHelloIndicatesDowngrade(self: *const Self) bool {
                    return mem.eql(u8, self.server_random[24..31], "DOWNGRD") and
                        self.server_random[31] == 0x01;
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

                fn processEncryptedExtensions(self: *Self, data: []const u8) HandshakeError!void {
                    if (self.state != .wait_encrypted_extensions) return error.UnexpectedMessage;

                    if (data.len < 2) return error.InvalidHandshake;
                    const total_ext_len = mem.readInt(u16, data[0..2], .big);
                    if (data.len != 2 + total_ext_len) return error.InvalidHandshake;

                    var pos: usize = 2;
                    const ext_end = 2 + total_ext_len;
                    while (pos < ext_end) {
                        if (pos + 4 > ext_end) return error.InvalidHandshake;
                        const ext_len = mem.readInt(u16, data[pos + 2 ..][0..2], .big);
                        pos += 4;
                        if (pos + ext_len > ext_end) return error.InvalidHandshake;
                        pos += ext_len;
                    }

                    self.state = .wait_certificate;
                }

                fn processCertificate(self: *Self, data: []const u8) HandshakeError!void {
                    if (self.state != .wait_certificate) return error.UnexpectedMessage;
                    if (data.len < 3) return error.InvalidHandshake;

                    var pos: usize = 0;
                    if (self.version == .tls_1_3) {
                        const context_len = data[0];
                        pos = 1;
                        if (pos + context_len + 3 > data.len) return error.InvalidHandshake;
                        pos += context_len;
                    }

                    const certs_len = mem.readInt(u24, data[pos..][0..3], .big);
                    pos += 3;
                    if (pos + certs_len > data.len) return error.InvalidHandshake;
                    const certs_end = pos + certs_len;

                    const now_sec = certificateNowSeconds();
                    var cert_index: usize = 0;
                    var prev_cert: ?crypto.Certificate.Parsed = null;
                    var chain_established = switch (self.verification) {
                        .no_verification, .hostname_only => true,
                        else => false,
                    };

                    while (pos < certs_end) {
                        if (pos + 3 > certs_end) return error.InvalidHandshake;
                        const cert_len = mem.readInt(u24, data[pos..][0..3], .big);
                        pos += 3;
                        if (pos + cert_len > certs_end) return error.InvalidHandshake;
                        const cert_der = data[pos..][0..cert_len];
                        pos += cert_len;

                        if (self.version == .tls_1_3) {
                            if (pos + 2 > certs_end) return error.InvalidHandshake;
                            const ext_len = mem.readInt(u16, data[pos..][0..2], .big);
                            pos += 2;
                            if (pos + ext_len > certs_end) return error.InvalidHandshake;
                            pos += ext_len;
                        }

                        if (cert_index == 0) {
                            if (cert_len > self.server_cert_der.len) return error.InvalidHandshake;
                            @memcpy(self.server_cert_der[0..cert_len], cert_der);
                            self.server_cert_der_len = cert_len;
                        }

                        const cert = certificateFromBytes(cert_der, 0);
                        const parsed = crypto.Certificate.parse(cert) catch return error.InvalidHandshake;

                        if (cert_index == 0 and hostnameVerificationEnabled(self.verification)) {
                            parsed.verifyHostName(self.hostname) catch return error.InvalidHandshake;
                        } else if (prev_cert) |issuer_candidate| {
                            if (verificationNeedsChain(self.verification)) {
                                issuer_candidate.verify(parsed, now_sec) catch |err| return mapCertificateError(err);
                            }
                        }

                        switch (self.verification) {
                            .bundle => |bundle| {
                                if (bundle.verify(parsed, now_sec)) |_| {
                                    chain_established = true;
                                } else |err| switch (err) {
                                    error.CertificateIssuerNotFound => {},
                                    else => return mapCertificateError(err),
                                }
                            },
                            else => {},
                        }

                        prev_cert = parsed;
                        cert_index += 1;
                    }

                    if (cert_index == 0) return error.InvalidHandshake;

                    switch (self.verification) {
                        .self_signed => {
                            const root_cert = prev_cert orelse return error.InvalidHandshake;
                            root_cert.verify(root_cert, now_sec) catch |err| return mapCertificateError(err);
                        },
                        .bundle => if (!chain_established) return error.UnknownCa,
                        else => {},
                    }

                    self.state = if (self.version == .tls_1_3)
                        .wait_certificate_verify
                    else
                        .wait_server_key_exchange;
                }

                fn processServerKeyExchange(self: *Self, data: []const u8) HandshakeError!void {
                    if (self.version != .tls_1_2) return error.UnexpectedMessage;
                    if (self.state != .wait_server_key_exchange) return error.UnexpectedMessage;
                    if (self.server_cert_der_len == 0) return error.InvalidHandshake;
                    if (data.len < 1 + 2 + 1 + 2 + 2) return error.InvalidHandshake;

                    var pos: usize = 0;
                    if (data[pos] != 0x03) return error.InvalidHandshake;
                    pos += 1;

                    const named_group: common.NamedGroup = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                    pos += 2;
                    const key_len = data[pos];
                    pos += 1;
                    if (pos + key_len + 2 + 2 > data.len) return error.InvalidHandshake;

                    const server_pub_key = data[pos..][0..key_len];
                    pos += key_len;
                    const params = data[0..pos];

                    const sig_scheme: common.SignatureScheme = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                    pos += 2;
                    const sig_len = mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2;
                    if (pos + sig_len != data.len) return error.InvalidHandshake;
                    const signature = data[pos..][0..sig_len];
                    const cert = certificateFromBytes(self.server_cert_der[0..self.server_cert_der_len], 0);
                    const parsed = crypto.Certificate.parse(cert) catch return error.InvalidHandshake;

                    var signed_message: [32 + 32 + 1 + 2 + 1 + 256]u8 = undefined;
                    const needed = self.client_random.len + self.server_random.len + params.len;
                    if (needed > signed_message.len) return error.InvalidHandshake;
                    var msg_pos: usize = 0;
                    @memcpy(signed_message[msg_pos..][0..self.client_random.len], &self.client_random);
                    msg_pos += self.client_random.len;
                    @memcpy(signed_message[msg_pos..][0..self.server_random.len], &self.server_random);
                    msg_pos += self.server_random.len;
                    @memcpy(signed_message[msg_pos..][0..params.len], params);
                    msg_pos += params.len;

                    try verifyServerSignature(sig_scheme, signed_message[0..msg_pos], signature, parsed.pubKey());
                    try self.computeTls12SharedSecret(named_group, server_pub_key);
                    self.tls12_negotiated_group = named_group;
                    self.state = .wait_server_hello_done;
                }

                fn processServerHelloDone(self: *Self, data: []const u8) HandshakeError!void {
                    if (self.version != .tls_1_2) return error.UnexpectedMessage;
                    if (self.state != .wait_server_hello_done) return error.UnexpectedMessage;
                    if (data.len != 0) return error.InvalidHandshake;
                    self.state = .wait_finished;
                }

                fn processCertificateVerify(self: *Self, data: []const u8) HandshakeError!void {
                    if (self.version != .tls_1_3) return error.UnexpectedMessage;
                    if (self.state != .wait_certificate_verify) return error.UnexpectedMessage;
                    if (data.len < 4 or self.server_cert_der_len == 0) return error.InvalidHandshake;

                    const sig_scheme: common.SignatureScheme = @enumFromInt(mem.readInt(u16, data[0..2], .big));
                    const sig_len = mem.readInt(u16, data[2..4], .big);
                    if (4 + sig_len != data.len) return error.InvalidHandshake;
                    const signature = data[4..][0..sig_len];

                    const cert = certificateFromBytes(self.server_cert_der[0..self.server_cert_der_len], 0);
                    const parsed = crypto.Certificate.parse(cert) catch return error.InvalidHandshake;
                    var transcript_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const transcript = try self.tls13TranscriptHash(&transcript_buf);

                    const context_string = "TLS 1.3, server CertificateVerify";
                    var content: [64 + context_string.len + 1 + kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    @memset(content[0..64], 0x20);
                    @memcpy(content[64..][0..context_string.len], context_string);
                    content[64 + context_string.len] = 0;
                    @memcpy(content[64 + context_string.len + 1 ..][0..transcript.len], transcript);

                    try verifyServerSignature(sig_scheme, content[0 .. 64 + context_string.len + 1 + transcript.len], signature, parsed.pubKey());
                    self.state = .wait_finished;
                }

                pub fn processServerFinished(self: *Self, data: []const u8, raw_msg: []const u8) HandshakeError!void {
                    if (self.state != .wait_finished) return error.UnexpectedMessage;
                    if (self.version == .tls_1_2) {
                        if (!self.tls12_server_ccs_received) return error.UnexpectedMessage;
                        if (data.len != self.tls12_expected_server_verify_data.len) return error.InvalidHandshake;
                        if (!mem.eql(u8, data, &self.tls12_expected_server_verify_data)) return error.BadRecordMac;
                        self.transcript_hash.update(raw_msg);
                        self.state = .connected;
                        return;
                    }

                    var expected_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const expected = try self.serverFinishedVerifyData(&expected_buf);
                    if (data.len != expected.len) return error.InvalidHandshake;
                    if (!mem.eql(u8, data, expected)) return error.BadRecordMac;

                    self.transcript_hash.update(raw_msg);
                    try self.deriveApplicationKeys();
                    try self.setReadCipherFromTrafficSecret(try self.tls13Secret(&self.server_application_traffic_secret));
                    self.server_finished_received = true;
                }

                pub fn writeClientFinished(self: *Self, handshake_buf: []u8, record_buf: []u8) HandshakeError!usize {
                    if (self.version != .tls_1_3) return error.UnexpectedMessage;
                    if (self.state != .wait_finished) return error.UnexpectedMessage;

                    var verify_data_buf: [kdf.MAX_TLS13_DIGEST_LEN]u8 = undefined;
                    const verify_data = try self.clientFinishedVerifyData(&verify_data_buf);
                    const total_len = common.HandshakeHeader.SIZE + verify_data.len;
                    if (handshake_buf.len < total_len) return error.BufferTooSmall;

                    try self.setWriteCipherFromTrafficSecret(try self.tls13Secret(&self.client_handshake_traffic_secret));

                    const header: common.HandshakeHeader = .{
                        .msg_type = .finished,
                        .length = @intCast(verify_data.len),
                    };
                    try header.serialize(handshake_buf[0..common.HandshakeHeader.SIZE]);
                    @memcpy(handshake_buf[common.HandshakeHeader.SIZE..][0..verify_data.len], verify_data);

                    _ = self.records.writeRecord(.handshake, handshake_buf[0..total_len], record_buf, handshake_buf) catch {
                        return error.RecordIoFailed;
                    };

                    self.transcript_hash.update(handshake_buf[0..total_len]);
                    try self.setWriteCipherFromTrafficSecret(try self.tls13Secret(&self.client_application_traffic_secret));
                    self.state = .connected;
                    return total_len;
                }

                pub fn writeClientFlight(self: *Self, handshake_buf: []u8, record_buf: []u8) HandshakeError!void {
                    switch (self.version) {
                        .tls_1_2 => try self.writeTls12ClientFlight(handshake_buf, record_buf),
                        else => _ = try self.writeClientFinished(handshake_buf, record_buf),
                    }
                }

                pub fn shouldSendClientFinished(self: *const Self) bool {
                    return switch (self.version) {
                        .tls_1_2 => self.state == .wait_finished and !self.tls12_client_flight_sent,
                        else => self.state == .wait_finished and self.server_finished_received,
                    };
                }

                pub fn processChangeCipherSpec(self: *Self, data: []const u8) HandshakeError!void {
                    if (data.len != 1 or data[0] != @intFromEnum(common.ChangeCipherSpecType.change_cipher_spec)) {
                        return error.InvalidHandshake;
                    }
                    if (self.version != .tls_1_2) return;
                    if (self.state != .wait_finished or !self.tls12_client_flight_sent) return error.UnexpectedMessage;
                    self.records.setReadCipher(self.tls12_server_cipher);
                    self.tls12_server_ccs_received = true;
                }

                fn writeTls12ClientFlight(self: *Self, handshake_buf: []u8, record_buf: []u8) HandshakeError!void {
                    if (self.state != .wait_finished or self.tls12_client_flight_sent) return error.UnexpectedMessage;

                    var public_key_buf: [97]u8 = undefined;
                    const public_key = self.tls12ClientPublicKey(&public_key_buf) orelse return error.KeyExchangeFailed;
                    const total_len = common.HandshakeHeader.SIZE + 1 + public_key.len;
                    if (handshake_buf.len < total_len) return error.BufferTooSmall;

                    const header: common.HandshakeHeader = .{
                        .msg_type = .client_key_exchange,
                        .length = @intCast(1 + public_key.len),
                    };
                    try header.serialize(handshake_buf[0..common.HandshakeHeader.SIZE]);
                    handshake_buf[common.HandshakeHeader.SIZE] = @intCast(public_key.len);
                    @memcpy(handshake_buf[common.HandshakeHeader.SIZE + 1 ..][0..public_key.len], public_key);
                    self.records.setVersion(.tls_1_2);
                    _ = self.records.writeRecord(.handshake, handshake_buf[0..total_len], record_buf, handshake_buf) catch {
                        return error.RecordIoFailed;
                    };
                    self.transcript_hash.update(handshake_buf[0..total_len]);

                    try self.deriveTls12Secrets();

                    const ccs = [_]u8{@intFromEnum(common.ChangeCipherSpecType.change_cipher_spec)};
                    _ = self.records.writeRecord(.change_cipher_spec, &ccs, record_buf, handshake_buf) catch {
                        return error.RecordIoFailed;
                    };

                    self.records.setWriteCipher(self.tls12_client_cipher);

                    const verify_data = self.tls12ClientFinishedVerifyData();
                    const finished_len = common.HandshakeHeader.SIZE + verify_data.len;
                    if (handshake_buf.len < finished_len) return error.BufferTooSmall;
                    const finished_header: common.HandshakeHeader = .{
                        .msg_type = .finished,
                        .length = verify_data.len,
                    };
                    try finished_header.serialize(handshake_buf[0..common.HandshakeHeader.SIZE]);
                    @memcpy(handshake_buf[common.HandshakeHeader.SIZE..][0..verify_data.len], &verify_data);

                    _ = self.records.writeRecord(.handshake, handshake_buf[0..finished_len], record_buf, handshake_buf) catch {
                        return error.RecordIoFailed;
                    };
                    self.transcript_hash.update(handshake_buf[0..finished_len]);
                    self.tls12_expected_server_verify_data = self.tls12ServerFinishedVerifyData();
                    self.tls12_client_flight_sent = true;
                }

                fn deriveTls12Secrets(self: *Self) HandshakeError!void {
                    const shared_secret = self.tls12SharedSecret() orelse return error.KeyExchangeFailed;
                    if (!self.clientSupportsTls12CipherSuite(self.cipher_suite)) return error.UnsupportedCipherSuite;

                    var master_seed: [64]u8 = undefined;
                    @memcpy(master_seed[0..32], &self.client_random);
                    @memcpy(master_seed[32..64], &self.server_random);
                    kdf.tls12PrfSha256(&self.tls12_master_secret, shared_secret, "master secret", &master_seed);

                    const key_len = self.cipher_suite.keyLength();
                    const fixed_iv_len = self.cipher_suite.tls12FixedIvLength();
                    if (key_len == 0 or fixed_iv_len == 0) return error.UnsupportedCipherSuite;

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
                }

                fn tls12ClientPublicKey(self: *const Self, out: *[97]u8) ?[]const u8 {
                    return switch (self.tls12_negotiated_group orelse return null) {
                        .secp256r1 => blk: {
                            const bytes = self.tls12_secp256r1_keypair.public_key.toUncompressedSec1();
                            @memcpy(out[0..bytes.len], &bytes);
                            break :blk out[0..bytes.len];
                        },
                        .secp384r1 => blk: {
                            const bytes = self.tls12_secp384r1_keypair.public_key.toUncompressedSec1();
                            @memcpy(out[0..bytes.len], &bytes);
                            break :blk out[0..bytes.len];
                        },
                        .x25519 => self.key_exchange.publicKey(),
                        else => null,
                    };
                }

                fn computeTls12SharedSecret(
                    self: *Self,
                    named_group: common.NamedGroup,
                    server_pub_key: []const u8,
                ) HandshakeError!void {
                    switch (named_group) {
                        .secp256r1 => {
                            const PublicKey = crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey;
                            const pk = PublicKey.fromSec1(server_pub_key) catch return error.InvalidPublicKey;
                            const mul = pk.p.mulPublic(self.tls12_secp256r1_keypair.secret_key.bytes, .big) catch {
                                return error.KeyExchangeFailed;
                            };
                            const sk = mul.affineCoordinates().x.toBytes(.big);
                            @memcpy(self.tls12_shared_secret[0..sk.len], &sk);
                            self.tls12_shared_secret_len = sk.len;
                        },
                        .secp384r1 => {
                            const PublicKey = crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey;
                            const pk = PublicKey.fromSec1(server_pub_key) catch return error.InvalidPublicKey;
                            const mul = pk.p.mulPublic(self.tls12_secp384r1_keypair.secret_key.bytes, .big) catch {
                                return error.KeyExchangeFailed;
                            };
                            const sk = mul.affineCoordinates().x.toBytes(.big);
                            @memcpy(self.tls12_shared_secret[0..sk.len], &sk);
                            self.tls12_shared_secret_len = sk.len;
                        },
                        .x25519 => {
                            const shared_secret = try self.key_exchange.computeSharedSecret(server_pub_key);
                            @memcpy(self.tls12_shared_secret[0..shared_secret.len], shared_secret);
                            self.tls12_shared_secret_len = shared_secret.len;
                        },
                        else => return error.UnsupportedGroup,
                    }
                }

                fn tls12SharedSecret(self: *const Self) ?[]const u8 {
                    return if (self.tls12_shared_secret_len == 0)
                        null
                    else
                        self.tls12_shared_secret[0..self.tls12_shared_secret_len];
                }

                fn tls12ClientFinishedVerifyData(self: *Self) [12]u8 {
                    const transcript = self.transcript_hash.peekSha256();
                    var verify_data: [12]u8 = undefined;
                    kdf.tls12PrfSha256(&verify_data, &self.tls12_master_secret, "client finished", &transcript);
                    return verify_data;
                }

                fn tls12ServerFinishedVerifyData(self: *Self) [12]u8 {
                    const transcript = self.transcript_hash.peekSha256();
                    var verify_data: [12]u8 = undefined;
                    kdf.tls12PrfSha256(&verify_data, &self.tls12_master_secret, "server finished", &transcript);
                    return verify_data;
                }

                fn deriveHandshakeKeys(self: *Self, shared_secret: []const u8) HandshakeError!void {
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
                    kdf.hkdfExpandLabelIntoProfile(profile, derived_buf[0..profile.secretLength()], early_secret, "derived", empty_hash);

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
                    try self.setReadCipherFromTrafficSecret(try self.tls13Secret(&self.server_handshake_traffic_secret));
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

                fn setReadCipherFromTrafficSecret(self: *Self, traffic_secret: []const u8) HandshakeError!void {
                    const cipher = try self.cipherFromTrafficSecret(traffic_secret);
                    self.records.setReadCipher(cipher);
                }

                fn setWriteCipherFromTrafficSecret(self: *Self, traffic_secret: []const u8) HandshakeError!void {
                    const cipher = try self.cipherFromTrafficSecret(traffic_secret);
                    self.records.setWriteCipher(cipher);
                }

                fn cipherFromTrafficSecret(
                    self: *Self,
                    traffic_secret: []const u8,
                ) HandshakeError!record.CipherState() {
                    const profile = try self.tls13Profile();
                    const key_len = self.cipher_suite.keyLength();
                    if (key_len != 16 and key_len != 32) return error.UnsupportedCipherSuite;

                    var iv: [12]u8 = undefined;
                    kdf.hkdfExpandLabelIntoProfile(profile, &iv, traffic_secret, "iv", "");
                    var key = [_]u8{0} ** 32;
                    if (key_len == 16) {
                        kdf.hkdfExpandLabelIntoProfile(profile, key[0..16], traffic_secret, "key", "");
                    } else {
                        kdf.hkdfExpandLabelIntoProfile(profile, key[0..32], traffic_secret, "key", "");
                    }

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

                fn hostnameVerificationEnabled(verification: VerificationMode) bool {
                    return switch (verification) {
                        .no_verification => false,
                        else => true,
                    };
                }

                fn verificationNeedsChain(verification: VerificationMode) bool {
                    return switch (verification) {
                        .self_signed, .bundle => true,
                        else => false,
                    };
                }

                fn certificateNowSeconds() i64 {
                    return @divFloor(time.milliTimestamp(), 1000);
                }

                fn mapCertificateError(err: anyerror) HandshakeError {
                    return switch (err) {
                        error.CertificateIssuerNotFound => error.UnknownCa,
                        else => error.InvalidHandshake,
                    };
                }

                fn certificateFromBytes(buffer: []const u8, index: u32) crypto.Certificate {
                    return .{
                        .buffer = buffer,
                        .index = index,
                    };
                }

                fn verifyServerSignature(
                    sig_scheme: common.SignatureScheme,
                    message: []const u8,
                    signature: []const u8,
                    pub_key: []const u8,
                ) HandshakeError!void {
                    switch (sig_scheme) {
                        .ecdsa_secp256r1_sha256 => {
                            const Sig = crypto.sign.ecdsa.EcdsaP256Sha256.Signature;
                            const PubKey = crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey;
                            const sig = Sig.fromDer(signature) catch return error.InvalidHandshake;
                            const key = PubKey.fromSec1(pub_key) catch return error.InvalidHandshake;
                            var verifier = sig.verifier(key) catch return error.InvalidHandshake;
                            verifier.update(message);
                            verifier.verify() catch return error.InvalidHandshake;
                        },
                        .ecdsa_secp384r1_sha384 => {
                            const Sig = crypto.sign.ecdsa.EcdsaP384Sha384.Signature;
                            const PubKey = crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey;
                            const sig = Sig.fromDer(signature) catch return error.InvalidHandshake;
                            const key = PubKey.fromSec1(pub_key) catch return error.InvalidHandshake;
                            var verifier = sig.verifier(key) catch return error.InvalidHandshake;
                            verifier.update(message);
                            verifier.verify() catch return error.InvalidHandshake;
                        },
                        .rsa_pkcs1_sha256 => try verifyRsaPkcs1v15(signature, message, pub_key, .sha256),
                        .rsa_pkcs1_sha384 => try verifyRsaPkcs1v15(signature, message, pub_key, .sha384),
                        .rsa_pkcs1_sha512 => try verifyRsaPkcs1v15(signature, message, pub_key, .sha512),
                        .rsa_pss_rsae_sha256, .rsa_pss_pss_sha256 => try verifyRsaPss(signature, message, pub_key, .sha256),
                        .rsa_pss_rsae_sha384, .rsa_pss_pss_sha384 => try verifyRsaPss(signature, message, pub_key, .sha384),
                        .rsa_pss_rsae_sha512, .rsa_pss_pss_sha512 => try verifyRsaPss(signature, message, pub_key, .sha512),
                        .ed25519 => {
                            const Sig = crypto.sign.Ed25519.Signature;
                            const PubKey = crypto.sign.Ed25519.PublicKey;
                            if (signature.len != Sig.encoded_length or pub_key.len != PubKey.encoded_length) return error.InvalidHandshake;
                            const sig = Sig.fromBytes(signature[0..Sig.encoded_length].*);
                            const key = PubKey.fromBytes(pub_key[0..PubKey.encoded_length].*) catch return error.InvalidHandshake;
                            var verifier = sig.verifier(key) catch return error.InvalidHandshake;
                            verifier.update(message);
                            verifier.verify() catch return error.InvalidHandshake;
                        },
                        else => return error.InvalidHandshake,
                    }
                }

                const RsaHash = enum { sha256, sha384, sha512 };

                fn verifyRsaPkcs1v15(signature: []const u8, message: []const u8, pub_key: []const u8, hash: RsaHash) HandshakeError!void {
                    try verifyCertificateRsa(signature, message, pub_key, hash, false);
                }

                fn verifyRsaPss(signature: []const u8, message: []const u8, pub_key: []const u8, hash: RsaHash) HandshakeError!void {
                    try verifyCertificateRsa(signature, message, pub_key, hash, true);
                }

                fn verifyCertificateRsa(
                    signature: []const u8,
                    message: []const u8,
                    pub_key: []const u8,
                    hash: RsaHash,
                    use_pss: bool,
                ) HandshakeError!void {
                    const StdRsa = crypto.Certificate.rsa;
                    const components = StdRsa.PublicKey.parseDer(pub_key) catch return error.InvalidHandshake;
                    switch (components.modulus.len) {
                        inline 128, 256, 384, 512 => |modulus_len| {
                            const key = StdRsa.PublicKey.fromBytes(components.exponent, components.modulus) catch return error.InvalidHandshake;
                            if (use_pss) {
                                const sig = StdRsa.PSSSignature.fromBytes(modulus_len, signature);
                                switch (hash) {
                                    .sha256 => StdRsa.PSSSignature.concatVerify(modulus_len, sig, &.{message}, key, crypto.hash.sha2.Sha256) catch return error.InvalidHandshake,
                                    .sha384 => StdRsa.PSSSignature.concatVerify(modulus_len, sig, &.{message}, key, crypto.hash.sha2.Sha384) catch return error.InvalidHandshake,
                                    .sha512 => StdRsa.PSSSignature.concatVerify(modulus_len, sig, &.{message}, key, crypto.hash.sha2.Sha512) catch return error.InvalidHandshake,
                                }
                            } else {
                                const sig = StdRsa.PKCS1v1_5Signature.fromBytes(modulus_len, signature);
                                switch (hash) {
                                    .sha256 => StdRsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig, &.{message}, key, crypto.hash.sha2.Sha256) catch return error.InvalidHandshake,
                                    .sha384 => StdRsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig, &.{message}, key, crypto.hash.sha2.Sha384) catch return error.InvalidHandshake,
                                    .sha512 => StdRsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig, &.{message}, key, crypto.hash.sha2.Sha512) catch return error.InvalidHandshake,
                                }
                            }
                        },
                        else => return error.InvalidHandshake,
                    }
                }

                fn generateP256KeyPair() HandshakeError!crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair {
                    while (true) {
                        var seed: [crypto.sign.ecdsa.EcdsaP256Sha256.SecretKey.encoded_length]u8 = undefined;
                        crypto.random.bytes(&seed);
                        const secret = crypto.sign.ecdsa.EcdsaP256Sha256.SecretKey.fromBytes(seed) catch continue;
                        return crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.fromSecretKey(secret) catch continue;
                    }
                }

                fn generateP384KeyPair() HandshakeError!crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair {
                    while (true) {
                        var seed: [crypto.sign.ecdsa.EcdsaP384Sha384.SecretKey.encoded_length]u8 = undefined;
                        crypto.random.bytes(&seed);
                        const secret = crypto.sign.ecdsa.EcdsaP384Sha384.SecretKey.fromBytes(seed) catch continue;
                        return crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair.fromSecretKey(secret) catch continue;
                    }
                }

                fn mapExtensionError(err: anyerror) HandshakeError {
                    return switch (err) {
                        error.BufferTooSmall => error.BufferTooSmall,
                        else => error.InvalidHandshake,
                    };
                }
            };
        }
    };
}

test "net/unit_tests/tls/client_handshake/x25519_shared_secret_roundtrip" {
    const std = @import("std");
    const client = make(std);

    var a = try client.KeyExchange.generate(.x25519);
    var b = try client.KeyExchange.generate(.x25519);

    const secret_a = try a.computeSharedSecret(b.publicKey());
    const secret_b = try b.computeSharedSecret(a.publicKey());
    try std.testing.expectEqualSlices(u8, secret_a, secret_b);
}

test "net/unit_tests/tls/client_handshake/encodes_client_hello" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);

    var buf: [1024]u8 = undefined;
    const len = try hs.encodeClientHello(&buf);
    try std.testing.expect(len > tls_common.HandshakeHeader.SIZE);

    const header = try tls_common.HandshakeHeader.parse(buf[0..tls_common.HandshakeHeader.SIZE]);
    try std.testing.expectEqual(tls_common.HandshakeType.client_hello, header.msg_type);
    try std.testing.expectEqual(@as(usize, header.length), len - tls_common.HandshakeHeader.SIZE);
    try std.testing.expectEqual(@as(u8, 32), buf[tls_common.HandshakeHeader.SIZE + 34]);
}

test "net/unit_tests/tls/client_handshake/honors_tls13_only_version_range" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);
    const tls_ext = @import("extensions.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).initWithOptions(&conn, .{
        .hostname = "example.com",
        .allocator = std.testing.allocator,
        .verification = .hostname_only,
        .min_version = .tls_1_3,
        .max_version = .tls_1_3,
    });

    var buf: [1024]u8 = undefined;
    const len = try hs.encodeClientHello(&buf);
    const header = try tls_common.HandshakeHeader.parse(buf[0..tls_common.HandshakeHeader.SIZE]);
    const body = buf[tls_common.HandshakeHeader.SIZE..len][0..header.length];

    var pos: usize = 0;
    pos += 2; // legacy_version
    pos += 32; // client_random
    pos += 1 + body[pos]; // session_id

    const cipher_suites_len = std.mem.readInt(u16, body[pos..][0..2], .big);
    pos += 2 + cipher_suites_len;

    const compression_methods_len = body[pos];
    pos += 1 + compression_methods_len;

    const extensions_len = std.mem.readInt(u16, body[pos..][0..2], .big);
    pos += 2;

    const exts = try tls_ext.parseExtensions(body[pos..][0..extensions_len], std.testing.allocator);
    defer std.testing.allocator.free(exts);

    const supported_versions = tls_ext.findExtension(exts, .supported_versions).?;
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 0x04 }, supported_versions.data);
}

test "net/unit_tests/tls/client_handshake/honors_tls12_only_version_range" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);
    const tls_ext = @import("extensions.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).initWithOptions(&conn, .{
        .hostname = "example.com",
        .allocator = std.testing.allocator,
        .verification = .hostname_only,
        .min_version = .tls_1_2,
        .max_version = .tls_1_2,
    });

    var buf: [1024]u8 = undefined;
    const len = try hs.encodeClientHello(&buf);
    const header = try tls_common.HandshakeHeader.parse(buf[0..tls_common.HandshakeHeader.SIZE]);
    const body = buf[tls_common.HandshakeHeader.SIZE..len][0..header.length];

    var pos: usize = 0;
    pos += 2;
    pos += 32;
    pos += 1 + body[pos];

    const cipher_suites_len = std.mem.readInt(u16, body[pos..][0..2], .big);
    pos += 2 + cipher_suites_len;

    const compression_methods_len = body[pos];
    pos += 1 + compression_methods_len;

    const extensions_len = std.mem.readInt(u16, body[pos..][0..2], .big);
    pos += 2;

    const exts = try tls_ext.parseExtensions(body[pos..][0..extensions_len], std.testing.allocator);
    defer std.testing.allocator.free(exts);

    const supported_versions = tls_ext.findExtension(exts, .supported_versions).?;
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 0x03 }, supported_versions.data);
}

test "net/unit_tests/tls/client_handshake/honors_configured_tls12_cipher_suites" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).initWithOptions(&conn, .{
        .hostname = "example.com",
        .allocator = std.testing.allocator,
        .verification = .hostname_only,
        .min_version = .tls_1_2,
        .max_version = .tls_1_2,
        .tls12_cipher_suites = &.{.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256},
    });

    var buf: [1024]u8 = undefined;
    const len = try hs.encodeClientHello(&buf);
    const header = try tls_common.HandshakeHeader.parse(buf[0..tls_common.HandshakeHeader.SIZE]);
    const body = buf[tls_common.HandshakeHeader.SIZE..len][0..header.length];

    var pos: usize = 0;
    pos += 2;
    pos += 32;
    pos += 1 + body[pos];

    const cipher_suites_len = std.mem.readInt(u16, body[pos..][0..2], .big);
    pos += 2;
    try std.testing.expectEqual(@as(u16, 2), cipher_suites_len);
    const cipher_suite: tls_common.CipherSuite = @enumFromInt(std.mem.readInt(u16, body[pos..][0..2], .big));
    try std.testing.expectEqual(tls_common.CipherSuite.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256, cipher_suite);
}

test "net/unit_tests/tls/client_handshake/tls12_finished_flow_matches_std_tls_helpers" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);
    const tls_record = @import("record.zig").make(std);
    const fixtures = @import("test_fixtures.zig");
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

    const MockConn = struct {
        write_buf: [4096]u8 = undefined,
        write_len: usize = 0,

        pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
            return error.EndOfStream;
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

    const ReadConn = struct {
        data: []const u8,
        pos: usize = 0,

        pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
            if (self.pos >= self.data.len) return error.EndOfStream;
            const n = @min(buf.len, self.data.len - self.pos);
            @memcpy(buf[0..n], self.data[self.pos..][0..n]);
            self.pos += n;
            return n;
        }

        pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, BrokenPipe, TimedOut, Unexpected }!usize {
            return error.Unexpected;
        }

        pub fn close(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
        pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
        pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
    };

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).initWithOptions(&conn, .{
        .hostname = "example.com",
        .allocator = std.testing.allocator,
        .verification = .no_verification,
        .min_version = .tls_1_2,
        .max_version = .tls_1_2,
    });
    hs.state = .wait_server_hello;

    var client_hello: [1024]u8 = undefined;
    const client_hello_len = try hs.encodeClientHello(&client_hello);

    var server_hello: [256]u8 = undefined;
    var pos: usize = tls_common.HandshakeHeader.SIZE;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.ProtocolVersion.tls_1_2), .big);
    pos += 2;
    @memset(server_hello[pos..][0..32], 0xAA);
    pos += 32;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.CipherSuite.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256), .big);
    pos += 2;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], 0, .big);
    pos += 2;
    const server_hello_header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello,
        .length = @intCast(pos - tls_common.HandshakeHeader.SIZE),
    };
    try server_hello_header.serialize(server_hello[0..tls_common.HandshakeHeader.SIZE]);
    try hs.processHandshake(server_hello[0..pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_certificate, hs.state);
    try std.testing.expectEqual(tls_common.ProtocolVersion.tls_1_2, hs.version);

    var certificate_msg: [4 + 3 + 3 + fixtures.self_signed_cert_der.len]u8 = undefined;
    var cert_pos: usize = 4;
    std.mem.writeInt(u24, certificate_msg[cert_pos..][0..3], 3 + fixtures.self_signed_cert_der.len, .big);
    cert_pos += 3;
    std.mem.writeInt(u24, certificate_msg[cert_pos..][0..3], fixtures.self_signed_cert_der.len, .big);
    cert_pos += 3;
    @memcpy(certificate_msg[cert_pos..][0..fixtures.self_signed_cert_der.len], fixtures.self_signed_cert_der[0..]);
    cert_pos += fixtures.self_signed_cert_der.len;
    const certificate_header: tls_common.HandshakeHeader = .{
        .msg_type = .certificate,
        .length = @intCast(cert_pos - 4),
    };
    try certificate_header.serialize(certificate_msg[0..4]);
    try hs.processHandshake(certificate_msg[0..cert_pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_server_key_exchange, hs.state);

    const cert_sk = try Ecdsa.SecretKey.fromBytes(fixtures.self_signed_key_scalar);
    const cert_kp = try Ecdsa.KeyPair.fromSecretKey(cert_sk);
    const eph_scalar = [_]u8{0} ** 31 ++ [_]u8{1};
    const eph_sk = try Ecdsa.SecretKey.fromBytes(eph_scalar);
    const eph_kp = try Ecdsa.KeyPair.fromSecretKey(eph_sk);
    const server_pub = eph_kp.public_key.toUncompressedSec1();

    var ske_msg: [512]u8 = undefined;
    var ske_pos: usize = 4;
    ske_msg[ske_pos] = 0x03;
    ske_pos += 1;
    std.mem.writeInt(u16, ske_msg[ske_pos..][0..2], @intFromEnum(tls_common.NamedGroup.secp256r1), .big);
    ske_pos += 2;
    ske_msg[ske_pos] = @intCast(server_pub.len);
    ske_pos += 1;
    @memcpy(ske_msg[ske_pos..][0..server_pub.len], &server_pub);
    ske_pos += server_pub.len;
    const params = ske_msg[4..ske_pos];

    var signed_message: [32 + 32 + 1 + 2 + 1 + 65]u8 = undefined;
    var signed_pos: usize = 0;
    @memcpy(signed_message[signed_pos..][0..32], &hs.client_random);
    signed_pos += 32;
    @memcpy(signed_message[signed_pos..][0..32], &hs.server_random);
    signed_pos += 32;
    @memcpy(signed_message[signed_pos..][0..params.len], params);
    signed_pos += params.len;

    const ske_sig = try cert_kp.sign(signed_message[0..signed_pos], null);
    var sig_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = ske_sig.toDer(&sig_der_buf);

    std.mem.writeInt(u16, ske_msg[ske_pos..][0..2], @intFromEnum(tls_common.SignatureScheme.ecdsa_secp256r1_sha256), .big);
    ske_pos += 2;
    std.mem.writeInt(u16, ske_msg[ske_pos..][0..2], @intCast(sig_der.len), .big);
    ske_pos += 2;
    @memcpy(ske_msg[ske_pos..][0..sig_der.len], sig_der);
    ske_pos += sig_der.len;

    const ske_header: tls_common.HandshakeHeader = .{
        .msg_type = .server_key_exchange,
        .length = @intCast(ske_pos - 4),
    };
    try ske_header.serialize(ske_msg[0..4]);
    try hs.processHandshake(ske_msg[0..ske_pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_server_hello_done, hs.state);

    var shd_msg: [4]u8 = undefined;
    const shd_header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello_done,
        .length = 0,
    };
    try shd_header.serialize(&shd_msg);
    try hs.processHandshake(&shd_msg);
    try std.testing.expect(hs.shouldSendClientFinished());

    const expected_master_secret = std.crypto.tls.hmacExpandLabel(
        HmacSha256,
        hs.tls12_shared_secret[0..hs.tls12_shared_secret_len],
        &.{ "master secret", &hs.client_random, &hs.server_random },
        48,
    );

    var handshake_buf: [256]u8 = undefined;
    var record_buf: [512]u8 = undefined;
    try hs.writeClientFlight(&handshake_buf, &record_buf);
    try std.testing.expectEqual(client.HandshakeState.wait_finished, hs.state);
    try std.testing.expectEqualSlices(u8, &expected_master_secret, &hs.tls12_master_secret);

    var offset: usize = 0;
    const cke_record = try tls_common.RecordHeader.parse(conn.write_buf[offset..][0..tls_common.RecordHeader.SIZE]);
    try std.testing.expectEqual(tls_common.ContentType.handshake, cke_record.content_type);
    const cke_record_len = tls_common.RecordHeader.SIZE + cke_record.length;
    var transcript_before_client_finished = hs.transcript_hash;
    transcript_before_client_finished.reset();
    transcript_before_client_finished.update(client_hello[0..client_hello_len]);
    transcript_before_client_finished.update(server_hello[0..pos]);
    transcript_before_client_finished.update(certificate_msg[0..cert_pos]);
    transcript_before_client_finished.update(ske_msg[0..ske_pos]);
    transcript_before_client_finished.update(&shd_msg);
    transcript_before_client_finished.update(conn.write_buf[offset + tls_common.RecordHeader.SIZE .. offset + cke_record_len]);
    offset += cke_record_len;

    const ccs_record = try tls_common.RecordHeader.parse(conn.write_buf[offset..][0..tls_common.RecordHeader.SIZE]);
    try std.testing.expectEqual(tls_common.ContentType.change_cipher_spec, ccs_record.content_type);
    offset += tls_common.RecordHeader.SIZE + ccs_record.length;

    const finished_record = try tls_common.RecordHeader.parse(conn.write_buf[offset..][0..tls_common.RecordHeader.SIZE]);
    const finished_total_len = tls_common.RecordHeader.SIZE + finished_record.length;
    var read_conn = ReadConn{ .data = conn.write_buf[offset..][0..finished_total_len] };
    var layer = tls_record.RecordLayer(*ReadConn).init(&read_conn);
    layer.setVersion(.tls_1_2);
    layer.setReadCipher(hs.tls12_client_cipher);

    var cipher_buf: [256]u8 = undefined;
    var plaintext_out: [256]u8 = undefined;
    const finished_res = try layer.readRecord(&cipher_buf, &plaintext_out);
    try std.testing.expectEqual(tls_common.ContentType.handshake, finished_res.content_type);
    const finished_header = try tls_common.HandshakeHeader.parse(plaintext_out[0..4]);
    try std.testing.expectEqual(tls_common.HandshakeType.finished, finished_header.msg_type);

    const transcript_before_finished = transcript_before_client_finished.peekSha256();
    const expected_client_verify = std.crypto.tls.hmacExpandLabel(
        HmacSha256,
        &expected_master_secret,
        &.{ "client finished", &transcript_before_finished },
        12,
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_client_verify,
        plaintext_out[4 .. 4 + finished_header.length],
    );

    const transcript_after_client_finished = hs.transcript_hash.peekSha256();
    const expected_server_verify = std.crypto.tls.hmacExpandLabel(
        HmacSha256,
        &expected_master_secret,
        &.{ "server finished", &transcript_after_client_finished },
        12,
    );
    try std.testing.expectEqualSlices(u8, &expected_server_verify, &hs.tls12_expected_server_verify_data);

    try hs.processChangeCipherSpec(&.{@intFromEnum(tls_common.ChangeCipherSpecType.change_cipher_spec)});

    var server_finished_msg: [4 + 12]u8 = undefined;
    const server_finished_header: tls_common.HandshakeHeader = .{
        .msg_type = .finished,
        .length = hs.tls12_expected_server_verify_data.len,
    };
    try server_finished_header.serialize(server_finished_msg[0..4]);
    @memcpy(server_finished_msg[4..], &hs.tls12_expected_server_verify_data);
    try hs.processServerFinished(server_finished_msg[4..], &server_finished_msg);
    try std.testing.expectEqual(client.HandshakeState.connected, hs.state);
}

test "net/unit_tests/tls/client_handshake/rejects_trailing_bytes_after_complete_handshake_message" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).initWithOptions(&conn, .{
        .hostname = "example.com",
        .allocator = std.testing.allocator,
        .verification = .no_verification,
        .min_version = .tls_1_2,
        .max_version = .tls_1_2,
    });
    hs.version = .tls_1_2;
    hs.state = .wait_server_hello_done;

    var msg: [5]u8 = undefined;
    const header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello_done,
        .length = 0,
    };
    try header.serialize(msg[0..tls_common.HandshakeHeader.SIZE]);
    msg[tls_common.HandshakeHeader.SIZE] = 0xAA;

    try std.testing.expectError(error.InvalidHandshake, hs.processHandshake(&msg));
}

test "net/unit_tests/tls/client_handshake/client_hello_matches_std_tls_overlapping_wire_fields" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);
    const tls_ext = @import("extensions.zig").make(std);

    const MockConn = struct {
        write_buf: [4096]u8 = undefined,
        write_len: usize = 0,

        pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
            return error.EndOfStream;
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

    const ParsedClientHello = struct {
        record_header: tls_common.RecordHeader,
        handshake_header: tls_common.HandshakeHeader,
        session_id: []const u8,
        cipher_suites: []const u8,
        compression_methods: []const u8,
        extensions_data: []const u8,
    };

    const Helpers = struct {
        fn parseClientHello(bytes: []const u8) !ParsedClientHello {
            const record_header = try tls_common.RecordHeader.parse(bytes[0..tls_common.RecordHeader.SIZE]);
            const record_len = tls_common.RecordHeader.SIZE + record_header.length;
            try std.testing.expect(bytes.len >= record_len);

            const handshake = bytes[tls_common.RecordHeader.SIZE..record_len];
            const handshake_header = try tls_common.HandshakeHeader.parse(handshake[0..tls_common.HandshakeHeader.SIZE]);
            const body = handshake[tls_common.HandshakeHeader.SIZE .. tls_common.HandshakeHeader.SIZE + handshake_header.length];

            var pos: usize = 0;
            pos += 2;
            pos += 32;

            const session_id_len = body[pos];
            pos += 1;
            const session_id = body[pos..][0..session_id_len];
            pos += session_id_len;

            const cipher_suites_len = std.mem.readInt(u16, body[pos..][0..2], .big);
            pos += 2;
            const cipher_suites = body[pos..][0..cipher_suites_len];
            pos += cipher_suites_len;

            const compression_methods_len = body[pos];
            pos += 1;
            const compression_methods = body[pos..][0..compression_methods_len];
            pos += compression_methods_len;

            const extensions_len = std.mem.readInt(u16, body[pos..][0..2], .big);
            pos += 2;
            const extensions_data = body[pos..][0..extensions_len];

            return .{
                .record_header = record_header,
                .handshake_header = handshake_header,
                .session_id = session_id,
                .cipher_suites = cipher_suites,
                .compression_methods = compression_methods,
                .extensions_data = extensions_data,
            };
        }

        fn expectSubsequence(needle: []const u8, haystack: []const u8) !void {
            var j: usize = 0;
            var i: usize = 0;
            while (i + 1 < haystack.len and j + 1 < needle.len) : (i += 2) {
                if (std.mem.eql(u8, needle[j .. j + 2], haystack[i .. i + 2])) {
                    j += 2;
                }
            }
            try std.testing.expectEqual(needle.len, j);
        }

        fn expectContainsCipherSuite(encoded: []const u8, suite: tls_common.CipherSuite) !void {
            var i: usize = 0;
            while (i + 1 < encoded.len) : (i += 2) {
                const got: tls_common.CipherSuite = @enumFromInt(std.mem.readInt(u16, encoded[i..][0..2], .big));
                if (got == suite) return;
            }
            return error.TestUnexpectedResult;
        }

        fn expectNotContainsCipherSuite(encoded: []const u8, suite: tls_common.CipherSuite) !void {
            var i: usize = 0;
            while (i + 1 < encoded.len) : (i += 2) {
                const got: tls_common.CipherSuite = @enumFromInt(std.mem.readInt(u16, encoded[i..][0..2], .big));
                if (got == suite) return error.TestUnexpectedResult;
            }
        }
    };

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);
    var handshake_buf: [4096]u8 = undefined;
    var record_buf: [4096]u8 = undefined;
    _ = try hs.sendClientHello(&handshake_buf, &record_buf);
    const ours = try Helpers.parseClientHello(conn.write_buf[0..conn.write_len]);

    var input_backing: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var input = std.Io.Reader.fixed(input_backing[0..]);
    input.seek = 0;
    input.end = 0;

    var output_backing: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(output_backing[0..]);
    var std_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var std_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    _ = std.crypto.tls.Client.init(&input, &output, .{
        .host = .{ .explicit = "example.com" },
        .ca = .no_verification,
        .read_buffer = &std_read_buf,
        .write_buffer = &std_write_buf,
    }) catch {};
    const std_hello = try Helpers.parseClientHello(output.buffered());

    try std.testing.expectEqual(std_hello.record_header.content_type, ours.record_header.content_type);
    try std.testing.expectEqual(std_hello.handshake_header.msg_type, ours.handshake_header.msg_type);
    try std.testing.expectEqual(std_hello.record_header.legacy_version, ours.record_header.legacy_version);
    try std.testing.expectEqual(@as(usize, 32), ours.session_id.len);
    try std.testing.expectEqual(std_hello.session_id.len, ours.session_id.len);
    try std.testing.expectEqualSlices(u8, std_hello.compression_methods, ours.compression_methods);

    const our_exts = try tls_ext.parseExtensions(ours.extensions_data, std.testing.allocator);
    defer std.testing.allocator.free(our_exts);
    const std_exts = try tls_ext.parseExtensions(std_hello.extensions_data, std.testing.allocator);
    defer std.testing.allocator.free(std_exts);

    for ([_]tls_common.ExtensionType{
        .server_name,
        .supported_versions,
        .signature_algorithms,
        .psk_key_exchange_modes,
    }) |ext_type| {
        const our_ext = tls_ext.findExtension(our_exts, ext_type).?;
        const std_ext = tls_ext.findExtension(std_exts, ext_type).?;
        try std.testing.expectEqualSlices(u8, std_ext.data, our_ext.data);
    }

    const our_groups = tls_ext.findExtension(our_exts, .supported_groups).?;
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x06, 0x00, 0x1d, 0x00, 0x17, 0x00, 0x18 }, our_groups.data);

    const our_key_share = tls_ext.findExtension(our_exts, .key_share).?;
    const std_key_share = tls_ext.findExtension(std_exts, .key_share).?;
    try std.testing.expect(our_key_share.data.len > 0);
    try std.testing.expect(std_key_share.data.len >= our_key_share.data.len);
    try Helpers.expectContainsCipherSuite(ours.cipher_suites, .TLS_AES_128_GCM_SHA256);
    try Helpers.expectContainsCipherSuite(ours.cipher_suites, .TLS_CHACHA20_POLY1305_SHA256);
    try Helpers.expectContainsCipherSuite(ours.cipher_suites, .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256);
    try Helpers.expectContainsCipherSuite(ours.cipher_suites, .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256);
    try Helpers.expectContainsCipherSuite(ours.cipher_suites, .TLS_AES_256_GCM_SHA384);
}

test "net/unit_tests/tls/client_handshake/processes_tls13_server_hello" {
    const std = @import("std");
    const client = make(std);
    const tls_ext = @import("extensions.zig").make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);
    hs.state = .wait_server_hello;

    var client_hello: [1024]u8 = undefined;
    _ = try hs.encodeClientHello(&client_hello);

    const server_secret = [_]u8{0x42} ** std.crypto.dh.X25519.secret_length;
    const server_public = try std.crypto.dh.X25519.recoverPublicKey(server_secret);

    var ext_buf: [128]u8 = undefined;
    var ext_builder = tls_ext.ExtensionBuilder.init(&ext_buf);
    try ext_builder.addSelectedVersion(.tls_1_3);
    try ext_builder.addKeyShareServer(.{
        .group = .x25519,
        .key_exchange = &server_public,
    });
    const ext_data = ext_builder.getData();

    var server_hello: [256]u8 = undefined;
    var pos: usize = tls_common.HandshakeHeader.SIZE;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.ProtocolVersion.tls_1_2), .big);
    pos += 2;
    @memset(server_hello[pos..][0..32], 0xAA);
    pos += 32;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.CipherSuite.TLS_AES_128_GCM_SHA256), .big);
    pos += 2;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intCast(ext_data.len), .big);
    pos += 2;
    @memcpy(server_hello[pos..][0..ext_data.len], ext_data);
    pos += ext_data.len;

    const header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello,
        .length = @intCast(pos - tls_common.HandshakeHeader.SIZE),
    };
    try header.serialize(server_hello[0..tls_common.HandshakeHeader.SIZE]);

    try hs.processHandshake(server_hello[0..pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_encrypted_extensions, hs.state);
    try std.testing.expectEqual(tls_common.ProtocolVersion.tls_1_3, hs.version);
    try std.testing.expectEqual(tls_common.CipherSuite.TLS_AES_128_GCM_SHA256, hs.cipher_suite);
    try std.testing.expect(hs.records.read_cipher != .none);
    try std.testing.expect(!std.mem.allEqual(u8, &hs.server_handshake_traffic_secret, 0));
}

test "net/unit_tests/tls/client_handshake/rejects_tls13_server_hello_without_key_share" {
    const std = @import("std");
    const client = make(std);
    const tls_ext = @import("extensions.zig").make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);
    hs.state = .wait_server_hello;

    var ext_buf: [64]u8 = undefined;
    var ext_builder = tls_ext.ExtensionBuilder.init(&ext_buf);
    try ext_builder.addSelectedVersion(.tls_1_3);
    const ext_data = ext_builder.getData();

    var server_hello: [256]u8 = undefined;
    var pos: usize = tls_common.HandshakeHeader.SIZE;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.ProtocolVersion.tls_1_2), .big);
    pos += 2;
    @memset(server_hello[pos..][0..32], 0xAA);
    pos += 32;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.CipherSuite.TLS_AES_128_GCM_SHA256), .big);
    pos += 2;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intCast(ext_data.len), .big);
    pos += 2;
    @memcpy(server_hello[pos..][0..ext_data.len], ext_data);
    pos += ext_data.len;

    const header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello,
        .length = @intCast(pos - tls_common.HandshakeHeader.SIZE),
    };
    try header.serialize(server_hello[0..tls_common.HandshakeHeader.SIZE]);

    try std.testing.expectError(error.MissingExtension, hs.processHandshake(server_hello[0..pos]));
}

test "net/unit_tests/tls/client_handshake/rejects_tls13_suite_with_tls12_selected_version" {
    const std = @import("std");
    const client = make(std);
    const tls_ext = @import("extensions.zig").make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);
    hs.state = .wait_server_hello;

    const server_secret = [_]u8{0x24} ** std.crypto.dh.X25519.secret_length;
    const server_public = try std.crypto.dh.X25519.recoverPublicKey(server_secret);

    var ext_buf: [128]u8 = undefined;
    var ext_builder = tls_ext.ExtensionBuilder.init(&ext_buf);
    try ext_builder.addSelectedVersion(.tls_1_2);
    try ext_builder.addKeyShareServer(.{
        .group = .x25519,
        .key_exchange = &server_public,
    });
    const ext_data = ext_builder.getData();

    var server_hello: [256]u8 = undefined;
    var pos: usize = tls_common.HandshakeHeader.SIZE;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.ProtocolVersion.tls_1_2), .big);
    pos += 2;
    @memset(server_hello[pos..][0..32], 0xBB);
    pos += 32;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.CipherSuite.TLS_AES_128_GCM_SHA256), .big);
    pos += 2;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intCast(ext_data.len), .big);
    pos += 2;
    @memcpy(server_hello[pos..][0..ext_data.len], ext_data);
    pos += ext_data.len;

    const header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello,
        .length = @intCast(pos - tls_common.HandshakeHeader.SIZE),
    };
    try header.serialize(server_hello[0..tls_common.HandshakeHeader.SIZE]);

    try std.testing.expectError(error.UnsupportedVersion, hs.processHandshake(server_hello[0..pos]));
}

test "net/unit_tests/tls/client_handshake/accepts_tls12_fallback_from_server_without_downgrade_sentinel" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);
    hs.state = .wait_server_hello;

    var server_hello: [128]u8 = undefined;
    var pos: usize = tls_common.HandshakeHeader.SIZE;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.ProtocolVersion.tls_1_2), .big);
    pos += 2;
    @memset(server_hello[pos..][0..32], 0xCD);
    pos += 32;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.CipherSuite.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256), .big);
    pos += 2;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], 0, .big);
    pos += 2;

    const header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello,
        .length = @intCast(pos - tls_common.HandshakeHeader.SIZE),
    };
    try header.serialize(server_hello[0..tls_common.HandshakeHeader.SIZE]);

    try hs.processHandshake(server_hello[0..pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_certificate, hs.state);
    try std.testing.expectEqual(tls_common.ProtocolVersion.tls_1_2, hs.version);
    try std.testing.expectEqual(tls_common.CipherSuite.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256, hs.cipher_suite);
}

test "net/unit_tests/tls/client_handshake/accepts_tls12_chacha_server_hello" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);
    hs.state = .wait_server_hello;

    var server_hello: [128]u8 = undefined;
    var pos: usize = tls_common.HandshakeHeader.SIZE;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.ProtocolVersion.tls_1_2), .big);
    pos += 2;
    @memset(server_hello[pos..][0..32], 0xEF);
    pos += 32;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.CipherSuite.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256), .big);
    pos += 2;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], 0, .big);
    pos += 2;

    const header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello,
        .length = @intCast(pos - tls_common.HandshakeHeader.SIZE),
    };
    try header.serialize(server_hello[0..tls_common.HandshakeHeader.SIZE]);

    try hs.processHandshake(server_hello[0..pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_certificate, hs.state);
    try std.testing.expectEqual(tls_common.ProtocolVersion.tls_1_2, hs.version);
    try std.testing.expectEqual(tls_common.CipherSuite.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256, hs.cipher_suite);
}

test "net/unit_tests/tls/client_handshake/rejects_tls12_downgrade_sentinel_when_tls13_was_offered" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);

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

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);
    hs.state = .wait_server_hello;

    var server_hello: [128]u8 = undefined;
    var pos: usize = tls_common.HandshakeHeader.SIZE;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.ProtocolVersion.tls_1_2), .big);
    pos += 2;
    @memset(server_hello[pos..][0..32], 0xAB);
    @memcpy(server_hello[pos + 24 ..][0..7], "DOWNGRD");
    server_hello[pos + 31] = 0x01;
    pos += 32;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.CipherSuite.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256), .big);
    pos += 2;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], 0, .big);
    pos += 2;

    const header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello,
        .length = @intCast(pos - tls_common.HandshakeHeader.SIZE),
    };
    try header.serialize(server_hello[0..tls_common.HandshakeHeader.SIZE]);

    try std.testing.expectError(error.InvalidHandshake, hs.processHandshake(server_hello[0..pos]));
}

test "net/unit_tests/tls/client_handshake/finished_flow_matches_std_tls_helpers" {
    const std = @import("std");
    const client = make(std);
    const tls_ext = @import("extensions.zig").make(std);
    const tls_common = @import("common.zig").make(std);
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

    const MockConn = struct {
        write_buf: [4096]u8 = undefined,
        write_len: usize = 0,

        pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
            return error.EndOfStream;
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

    const cert_der = [_]u8{
        0x30, 0x82, 0x01, 0x99, 0x30, 0x82, 0x01, 0x3f, 0xa0, 0x03, 0x02, 0x01,
        0x02, 0x02, 0x14, 0x1f, 0x30, 0x92, 0xee, 0x83, 0xf5, 0xf2, 0x00, 0x6f,
        0xb4, 0x18, 0xb5, 0xae, 0x64, 0x0a, 0x3d, 0x88, 0x40, 0xb3, 0xc9, 0x30,
        0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x30,
        0x16, 0x31, 0x14, 0x30, 0x12, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x0b,
        0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d, 0x30,
        0x1e, 0x17, 0x0d, 0x32, 0x36, 0x30, 0x33, 0x32, 0x31, 0x31, 0x38, 0x30,
        0x37, 0x34, 0x39, 0x5a, 0x17, 0x0d, 0x33, 0x36, 0x30, 0x33, 0x31, 0x38,
        0x31, 0x38, 0x30, 0x37, 0x34, 0x39, 0x5a, 0x30, 0x16, 0x31, 0x14, 0x30,
        0x12, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x0b, 0x65, 0x78, 0x61, 0x6d,
        0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d, 0x30, 0x59, 0x30, 0x13, 0x06,
        0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04, 0xbc, 0x8a,
        0x8d, 0xd7, 0xa0, 0x7a, 0xe8, 0x75, 0x7a, 0x28, 0x97, 0xa3, 0xea, 0x6d,
        0xdf, 0x70, 0x4f, 0xd1, 0x75, 0x8b, 0xbb, 0xd8, 0xac, 0xbb, 0xf6, 0x1d,
        0x74, 0x3d, 0x4b, 0x1a, 0xeb, 0x38, 0x29, 0xa7, 0x3e, 0x7a, 0x9b, 0x69,
        0x6f, 0x71, 0x8c, 0xd3, 0x47, 0xb6, 0xda, 0xdc, 0xa4, 0xf1, 0x1d, 0xad,
        0xfc, 0x69, 0x23, 0x63, 0x3d, 0xfc, 0x47, 0x94, 0x71, 0x16, 0xb8, 0xae,
        0xde, 0x24, 0xa3, 0x6b, 0x30, 0x69, 0x30, 0x1d, 0x06, 0x03, 0x55, 0x1d,
        0x0e, 0x04, 0x16, 0x04, 0x14, 0x0a, 0xe2, 0x83, 0x3c, 0xd7, 0x9b, 0xd6,
        0x53, 0x6a, 0xd1, 0xda, 0x5d, 0x59, 0x4f, 0x18, 0xbe, 0x39, 0xff, 0x12,
        0xe7, 0x30, 0x1f, 0x06, 0x03, 0x55, 0x1d, 0x23, 0x04, 0x18, 0x30, 0x16,
        0x80, 0x14, 0x0a, 0xe2, 0x83, 0x3c, 0xd7, 0x9b, 0xd6, 0x53, 0x6a, 0xd1,
        0xda, 0x5d, 0x59, 0x4f, 0x18, 0xbe, 0x39, 0xff, 0x12, 0xe7, 0x30, 0x0f,
        0x06, 0x03, 0x55, 0x1d, 0x13, 0x01, 0x01, 0xff, 0x04, 0x05, 0x30, 0x03,
        0x01, 0x01, 0xff, 0x30, 0x16, 0x06, 0x03, 0x55, 0x1d, 0x11, 0x04, 0x0f,
        0x30, 0x0d, 0x82, 0x0b, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e,
        0x63, 0x6f, 0x6d, 0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
        0x04, 0x03, 0x02, 0x03, 0x48, 0x00, 0x30, 0x45, 0x02, 0x20, 0x40, 0xb6,
        0x99, 0xa2, 0x64, 0x0f, 0x19, 0x85, 0xe5, 0x90, 0xc5, 0x2e, 0x5f, 0x2c,
        0x7d, 0xab, 0x61, 0x04, 0x99, 0x40, 0x94, 0x7a, 0x2c, 0x50, 0x88, 0xf9,
        0xc1, 0x60, 0xcc, 0x34, 0x79, 0xf4, 0x02, 0x21, 0x00, 0x88, 0x86, 0xf0,
        0xb9, 0xb2, 0x07, 0x25, 0x57, 0x55, 0x60, 0x83, 0xe1, 0x9a, 0x4d, 0x20,
        0x8f, 0xaa, 0x39, 0xfe, 0xe5, 0xd8, 0x5f, 0xfc, 0x10, 0xfe, 0xd4, 0xb3,
        0x09, 0xd3, 0x38, 0xda, 0x05,
    };
    const key_scalar = [_]u8{
        0x56, 0xbf, 0x56, 0xe5, 0xa9, 0xa9, 0x14, 0x72,
        0x61, 0xfa, 0x38, 0x27, 0x46, 0x7b, 0xa4, 0xe1,
        0x20, 0x28, 0xf7, 0x4b, 0x84, 0xe3, 0xbc, 0x86,
        0xb7, 0x3e, 0x34, 0x8e, 0x51, 0x06, 0x69, 0x17,
    };

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).init(&conn, "example.com", std.testing.allocator, false);
    hs.state = .wait_server_hello;

    var client_hello: [1024]u8 = undefined;
    _ = try hs.encodeClientHello(&client_hello);

    const server_secret = [_]u8{0x42} ** std.crypto.dh.X25519.secret_length;
    const server_public = try std.crypto.dh.X25519.recoverPublicKey(server_secret);

    var ext_buf: [128]u8 = undefined;
    var ext_builder = tls_ext.ExtensionBuilder.init(&ext_buf);
    try ext_builder.addSelectedVersion(.tls_1_3);
    try ext_builder.addKeyShareServer(.{
        .group = .x25519,
        .key_exchange = &server_public,
    });
    const ext_data = ext_builder.getData();

    var server_hello: [256]u8 = undefined;
    var pos: usize = tls_common.HandshakeHeader.SIZE;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.ProtocolVersion.tls_1_2), .big);
    pos += 2;
    @memset(server_hello[pos..][0..32], 0xAA);
    pos += 32;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intFromEnum(tls_common.CipherSuite.TLS_AES_128_GCM_SHA256), .big);
    pos += 2;
    server_hello[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, server_hello[pos..][0..2], @intCast(ext_data.len), .big);
    pos += 2;
    @memcpy(server_hello[pos..][0..ext_data.len], ext_data);
    pos += ext_data.len;
    const server_hello_header: tls_common.HandshakeHeader = .{
        .msg_type = .server_hello,
        .length = @intCast(pos - tls_common.HandshakeHeader.SIZE),
    };
    try server_hello_header.serialize(server_hello[0..tls_common.HandshakeHeader.SIZE]);
    try hs.processHandshake(server_hello[0..pos]);

    var encrypted_extensions = [_]u8{
        @intFromEnum(tls_common.HandshakeType.encrypted_extensions),
        0x00,
        0x00,
        0x02,
        0x00,
        0x00,
    };
    try hs.processHandshake(&encrypted_extensions);
    try std.testing.expectEqual(client.HandshakeState.wait_certificate, hs.state);

    var certificate_msg: [4 + 1 + 3 + 3 + cert_der.len + 2]u8 = undefined;
    var cert_pos: usize = 4;
    certificate_msg[cert_pos] = 0;
    cert_pos += 1;
    std.mem.writeInt(u24, certificate_msg[cert_pos..][0..3], 3 + cert_der.len + 2, .big);
    cert_pos += 3;
    std.mem.writeInt(u24, certificate_msg[cert_pos..][0..3], cert_der.len, .big);
    cert_pos += 3;
    @memcpy(certificate_msg[cert_pos..][0..cert_der.len], cert_der[0..]);
    cert_pos += cert_der.len;
    std.mem.writeInt(u16, certificate_msg[cert_pos..][0..2], 0, .big);
    cert_pos += 2;
    const certificate_header: tls_common.HandshakeHeader = .{
        .msg_type = .certificate,
        .length = @intCast(cert_pos - 4),
    };
    try certificate_header.serialize(certificate_msg[0..4]);
    try hs.processHandshake(certificate_msg[0..cert_pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_certificate_verify, hs.state);

    const context_string = "TLS 1.3, server CertificateVerify";
    const transcript_before_cert_verify = hs.transcript_hash.peekSha256();
    var cert_verify_input: [64 + context_string.len + 1 + transcript_before_cert_verify.len]u8 = undefined;
    @memset(cert_verify_input[0..64], 0x20);
    @memcpy(cert_verify_input[64..][0..context_string.len], context_string);
    cert_verify_input[64 + context_string.len] = 0;
    @memcpy(cert_verify_input[64 + context_string.len + 1 ..][0..transcript_before_cert_verify.len], transcript_before_cert_verify[0..]);

    const sk = try Ecdsa.SecretKey.fromBytes(key_scalar);
    const kp = try Ecdsa.KeyPair.fromSecretKey(sk);
    const sig = try kp.sign(cert_verify_input[0..], null);
    var sig_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = sig.toDer(&sig_der_buf);

    var cert_verify_msg: [4 + 2 + 2 + Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    var cv_pos: usize = 4;
    std.mem.writeInt(u16, cert_verify_msg[cv_pos..][0..2], @intFromEnum(tls_common.SignatureScheme.ecdsa_secp256r1_sha256), .big);
    cv_pos += 2;
    std.mem.writeInt(u16, cert_verify_msg[cv_pos..][0..2], @intCast(sig_der.len), .big);
    cv_pos += 2;
    @memcpy(cert_verify_msg[cv_pos..][0..sig_der.len], sig_der);
    cv_pos += sig_der.len;
    const cert_verify_header: tls_common.HandshakeHeader = .{
        .msg_type = .certificate_verify,
        .length = @intCast(cv_pos - 4),
    };
    try cert_verify_header.serialize(cert_verify_msg[0..4]);
    try hs.processHandshake(cert_verify_msg[0..cv_pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_finished, hs.state);

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
    const server_finished_header: tls_common.HandshakeHeader = .{
        .msg_type = .finished,
        .length = expected_server_verify_data.len,
    };
    try server_finished_header.serialize(server_finished[0..4]);
    @memcpy(server_finished[4..], &expected_server_verify_data);
    try hs.processHandshake(&server_finished);

    const client_finished_key = std.crypto.tls.hkdfExpandLabel(
        std.crypto.kdf.hkdf.HkdfSha256,
        hs.client_handshake_traffic_secret[0..std.crypto.auth.hmac.sha2.HmacSha256.key_length].*,
        "finished",
        "",
        std.crypto.auth.hmac.sha2.HmacSha256.key_length,
    );
    const transcript_before_client_finished = hs.transcript_hash.peekSha256();
    const expected_client_verify_data = std.crypto.tls.hmac(
        std.crypto.auth.hmac.sha2.HmacSha256,
        &transcript_before_client_finished,
        client_finished_key,
    );

    var handshake_buf: [128]u8 = undefined;
    var record_buf: [256]u8 = undefined;
    const client_finished_len = try hs.writeClientFinished(&handshake_buf, &record_buf);
    const client_finished_header = try tls_common.HandshakeHeader.parse(handshake_buf[0..4]);
    try std.testing.expectEqual(@as(usize, 36), client_finished_len);
    try std.testing.expectEqual(tls_common.HandshakeType.finished, client_finished_header.msg_type);
    try std.testing.expectEqualSlices(u8, &expected_client_verify_data, handshake_buf[4..36]);
    try std.testing.expectEqual(client.HandshakeState.connected, hs.state);
}

test "net/unit_tests/tls/client_handshake/verifies_certificate_chain_with_bundle" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);
    const fixtures = @import("test_fixtures.zig");

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

    var bundle: std.crypto.Certificate.Bundle = .{};
    defer bundle.deinit(std.testing.allocator);
    const decoded_start: u32 = @intCast(bundle.bytes.items.len);
    try bundle.bytes.appendSlice(std.testing.allocator, fixtures.chain_root_der[0..]);
    try bundle.parseCert(std.testing.allocator, decoded_start, std.time.timestamp());

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).initWithOptions(&conn, .{
        .hostname = "example.com",
        .allocator = std.testing.allocator,
        .verification = .{ .bundle = &bundle },
    });
    hs.state = .wait_certificate;

    const certs_len = 3 + fixtures.chain_leaf_der.len + 2 + 3 + fixtures.chain_root_der.len + 2;
    var certificate_msg: [4 + 1 + 3 + certs_len]u8 = undefined;
    var pos: usize = 4;
    certificate_msg[pos] = 0;
    pos += 1;
    std.mem.writeInt(u24, certificate_msg[pos..][0..3], certs_len, .big);
    pos += 3;
    std.mem.writeInt(u24, certificate_msg[pos..][0..3], fixtures.chain_leaf_der.len, .big);
    pos += 3;
    @memcpy(certificate_msg[pos..][0..fixtures.chain_leaf_der.len], fixtures.chain_leaf_der[0..]);
    pos += fixtures.chain_leaf_der.len;
    std.mem.writeInt(u16, certificate_msg[pos..][0..2], 0, .big);
    pos += 2;
    std.mem.writeInt(u24, certificate_msg[pos..][0..3], fixtures.chain_root_der.len, .big);
    pos += 3;
    @memcpy(certificate_msg[pos..][0..fixtures.chain_root_der.len], fixtures.chain_root_der[0..]);
    pos += fixtures.chain_root_der.len;
    std.mem.writeInt(u16, certificate_msg[pos..][0..2], 0, .big);
    pos += 2;

    const certificate_header: tls_common.HandshakeHeader = .{
        .msg_type = .certificate,
        .length = @intCast(pos - 4),
    };
    try certificate_header.serialize(certificate_msg[0..4]);

    try hs.processHandshake(certificate_msg[0..pos]);
    try std.testing.expectEqual(client.HandshakeState.wait_certificate_verify, hs.state);
    try std.testing.expectEqual(@as(usize, fixtures.chain_leaf_der.len), hs.server_cert_der_len);
}

test "net/unit_tests/tls/client_handshake/rejects_unknown_certificate_authority" {
    const std = @import("std");
    const client = make(std);
    const tls_common = @import("common.zig").make(std);
    const fixtures = @import("test_fixtures.zig");

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

    var bundle: std.crypto.Certificate.Bundle = .{};
    defer bundle.deinit(std.testing.allocator);

    var conn = MockConn{};
    var hs = try client.ClientHandshake(*MockConn).initWithOptions(&conn, .{
        .hostname = "example.com",
        .allocator = std.testing.allocator,
        .verification = .{ .bundle = &bundle },
    });
    hs.state = .wait_certificate;

    const certs_len = 3 + fixtures.chain_leaf_der.len + 2 + 3 + fixtures.chain_root_der.len + 2;
    var certificate_msg: [4 + 1 + 3 + certs_len]u8 = undefined;
    var pos: usize = 4;
    certificate_msg[pos] = 0;
    pos += 1;
    std.mem.writeInt(u24, certificate_msg[pos..][0..3], certs_len, .big);
    pos += 3;
    std.mem.writeInt(u24, certificate_msg[pos..][0..3], fixtures.chain_leaf_der.len, .big);
    pos += 3;
    @memcpy(certificate_msg[pos..][0..fixtures.chain_leaf_der.len], fixtures.chain_leaf_der[0..]);
    pos += fixtures.chain_leaf_der.len;
    std.mem.writeInt(u16, certificate_msg[pos..][0..2], 0, .big);
    pos += 2;
    std.mem.writeInt(u24, certificate_msg[pos..][0..3], fixtures.chain_root_der.len, .big);
    pos += 3;
    @memcpy(certificate_msg[pos..][0..fixtures.chain_root_der.len], fixtures.chain_root_der[0..]);
    pos += fixtures.chain_root_der.len;
    std.mem.writeInt(u16, certificate_msg[pos..][0..2], 0, .big);
    pos += 2;

    const certificate_header: tls_common.HandshakeHeader = .{
        .msg_type = .certificate,
        .length = @intCast(pos - 4),
    };
    try certificate_header.serialize(certificate_msg[0..4]);

    try std.testing.expectError(error.UnknownCa, hs.processHandshake(certificate_msg[0..pos]));
}
