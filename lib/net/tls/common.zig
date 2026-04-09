const testing_api = @import("testing");

pub fn make(comptime lib: type) type {
    const crypto = lib.crypto;
    const mem = lib.mem;

    return struct {
        pub const Tls13Hash = enum {
            sha256,
            sha384,
        };

        pub const Tls13CipherProfile = struct {
            hash: Tls13Hash,

            pub fn secretLength(self: @This()) usize {
                return switch (self.hash) {
                    .sha256 => 32,
                    .sha384 => 48,
                };
            }

            pub fn digestLength(self: @This()) usize {
                return switch (self.hash) {
                    .sha256 => 32,
                    .sha384 => 48,
                };
            }
        };

        pub const ProtocolVersion = enum(u16) {
            tls_1_0 = 0x0301,
            tls_1_1 = 0x0302,
            tls_1_2 = 0x0303,
            tls_1_3 = 0x0304,
            _,

            pub fn name(self: ProtocolVersion) []const u8 {
                return switch (self) {
                    .tls_1_0 => "TLS 1.0",
                    .tls_1_1 => "TLS 1.1",
                    .tls_1_2 => "TLS 1.2",
                    .tls_1_3 => "TLS 1.3",
                    else => "unknown",
                };
            }
        };

        pub const ContentType = enum(u8) {
            change_cipher_spec = 20,
            alert = 21,
            handshake = 22,
            application_data = 23,
            _,
        };

        pub const HandshakeType = enum(u8) {
            client_hello = 1,
            server_hello = 2,
            new_session_ticket = 4,
            end_of_early_data = 5,
            encrypted_extensions = 8,
            certificate = 11,
            server_key_exchange = 12,
            certificate_request = 13,
            server_hello_done = 14,
            certificate_verify = 15,
            client_key_exchange = 16,
            finished = 20,
            key_update = 24,
            message_hash = 254,
            _,
        };

        pub const CipherSuite = enum(u16) {
            TLS_AES_128_GCM_SHA256 = 0x1301,
            TLS_AES_256_GCM_SHA384 = 0x1302,
            TLS_CHACHA20_POLY1305_SHA256 = 0x1303,

            TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 = 0xC02B,
            TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 = 0xC02C,
            TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 = 0xC02F,
            TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 = 0xC030,
            TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 = 0xCCA8,
            TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 = 0xCCA9,
            _,

            pub fn isTls13(self: CipherSuite) bool {
                return self.tls13Profile() != null;
            }

            pub fn tls13Profile(self: CipherSuite) ?Tls13CipherProfile {
                return switch (self) {
                    .TLS_AES_128_GCM_SHA256,
                    .TLS_CHACHA20_POLY1305_SHA256,
                    => .{ .hash = .sha256 },
                    .TLS_AES_256_GCM_SHA384 => .{ .hash = .sha384 },
                    else => null,
                };
            }

            pub fn keyLength(self: CipherSuite) u8 {
                return switch (self) {
                    .TLS_AES_128_GCM_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                    => 16,
                    .TLS_AES_256_GCM_SHA384,
                    .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                    .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                    .TLS_CHACHA20_POLY1305_SHA256,
                    .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                    => 32,
                    else => 0,
                };
            }

            pub fn ivLength(self: CipherSuite) u8 {
                return switch (self) {
                    .TLS_AES_128_GCM_SHA256,
                    .TLS_AES_256_GCM_SHA384,
                    .TLS_CHACHA20_POLY1305_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                    .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                    .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                    => 12,
                    else => 0,
                };
            }

            pub fn tls12FixedIvLength(self: CipherSuite) u8 {
                return switch (self) {
                    .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                    .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                    => 4,
                    .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                    => 12,
                    else => 0,
                };
            }

            pub fn tls12ExplicitNonceLength(self: CipherSuite) u8 {
                return switch (self) {
                    .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                    .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                    => 8,
                    .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                    => 0,
                    else => 0,
                };
            }

            pub fn tagLength(self: CipherSuite) u8 {
                return switch (self) {
                    .TLS_AES_128_GCM_SHA256,
                    .TLS_AES_256_GCM_SHA384,
                    .TLS_CHACHA20_POLY1305_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                    .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                    .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                    .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                    .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                    => 16,
                    else => 0,
                };
            }
        };

        pub const DEFAULT_TLS12_CIPHER_SUITES = [_]CipherSuite{
            .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
            .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
            .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
        };

        pub fn isSupportedTls12CipherSuite(suite: CipherSuite) bool {
            return switch (suite) {
                .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                => true,
                else => false,
            };
        }

        pub fn validateTls12CipherSuites(suites: []const CipherSuite) bool {
            if (suites.len == 0) return false;
            for (suites, 0..) |suite, i| {
                if (!isSupportedTls12CipherSuite(suite)) return false;
                for (suites[0..i]) |prev| {
                    if (prev == suite) return false;
                }
            }
            return true;
        }

        pub const DEFAULT_TLS13_CIPHER_SUITES = if (crypto.core.aes.has_hardware_support)
            [_]CipherSuite{
                .TLS_AES_128_GCM_SHA256,
                .TLS_AES_256_GCM_SHA384,
                .TLS_CHACHA20_POLY1305_SHA256,
            }
        else
            [_]CipherSuite{
                .TLS_CHACHA20_POLY1305_SHA256,
                .TLS_AES_128_GCM_SHA256,
                .TLS_AES_256_GCM_SHA384,
            };

        pub fn validateTls13CipherSuites(suites: []const CipherSuite) bool {
            if (suites.len == 0) return false;
            for (suites, 0..) |suite, i| {
                if (!suite.isTls13()) return false;
                for (suites[0..i]) |prev| {
                    if (prev == suite) return false;
                }
            }
            return true;
        }

        pub const NamedGroup = enum(u16) {
            secp256r1 = 23,
            secp384r1 = 24,
            secp521r1 = 25,
            x25519 = 29,
            x448 = 30,
            x25519_mlkem768 = 4588,
            _,
        };

        pub const SignatureScheme = enum(u16) {
            rsa_pkcs1_sha256 = 0x0401,
            rsa_pkcs1_sha384 = 0x0501,
            rsa_pkcs1_sha512 = 0x0601,

            ecdsa_secp256r1_sha256 = 0x0403,
            ecdsa_secp384r1_sha384 = 0x0503,
            ecdsa_secp521r1_sha512 = 0x0603,

            rsa_pss_rsae_sha256 = 0x0804,
            rsa_pss_rsae_sha384 = 0x0805,
            rsa_pss_rsae_sha512 = 0x0806,
            rsa_pss_pss_sha256 = 0x0809,
            rsa_pss_pss_sha384 = 0x080a,
            rsa_pss_pss_sha512 = 0x080b,

            ed25519 = 0x0807,
            ed448 = 0x0808,

            rsa_pkcs1_sha1 = 0x0201,
            ecdsa_sha1 = 0x0203,
            _,
        };

        pub const ExtensionType = enum(u16) {
            server_name = 0,
            max_fragment_length = 1,
            status_request = 5,
            supported_groups = 10,
            ec_point_formats = 11,
            signature_algorithms = 13,
            use_srtp = 14,
            heartbeat = 15,
            application_layer_protocol_negotiation = 16,
            signed_certificate_timestamp = 18,
            client_certificate_type = 19,
            server_certificate_type = 20,
            padding = 21,
            extended_master_secret = 23,
            session_ticket = 35,
            pre_shared_key = 41,
            early_data = 42,
            supported_versions = 43,
            cookie = 44,
            psk_key_exchange_modes = 45,
            certificate_authorities = 47,
            oid_filters = 48,
            post_handshake_auth = 49,
            signature_algorithms_cert = 50,
            key_share = 51,
            renegotiation_info = 65281,
            _,
        };

        pub const AlertLevel = enum(u8) {
            warning = 1,
            fatal = 2,
            _,
        };

        pub const AlertDescription = enum(u8) {
            close_notify = 0,
            unexpected_message = 10,
            bad_record_mac = 20,
            decryption_failed_reserved = 21,
            record_overflow = 22,
            decompression_failure_reserved = 30,
            handshake_failure = 40,
            no_certificate_reserved = 41,
            bad_certificate = 42,
            unsupported_certificate = 43,
            certificate_revoked = 44,
            certificate_expired = 45,
            certificate_unknown = 46,
            illegal_parameter = 47,
            unknown_ca = 48,
            access_denied = 49,
            decode_error = 50,
            decrypt_error = 51,
            export_restriction_reserved = 60,
            protocol_version = 70,
            insufficient_security = 71,
            internal_error = 80,
            inappropriate_fallback = 86,
            user_canceled = 90,
            no_renegotiation_reserved = 100,
            missing_extension = 109,
            unsupported_extension = 110,
            certificate_unobtainable_reserved = 111,
            unrecognized_name = 112,
            bad_certificate_status_response = 113,
            bad_certificate_hash_value_reserved = 114,
            unknown_psk_identity = 115,
            certificate_required = 116,
            no_application_protocol = 120,
            _,
        };

        pub const Alert = struct {
            level: AlertLevel,
            description: AlertDescription,
        };

        pub const ChangeCipherSpecType = enum(u8) {
            change_cipher_spec = 1,
            _,
        };

        pub const CompressionMethod = enum(u8) {
            null = 0,
            _,
        };

        pub const PskKeyExchangeMode = enum(u8) {
            psk_ke = 0,
            psk_dhe_ke = 1,
            _,
        };

        pub const MAX_PLAINTEXT_LEN = 16384;
        pub const MAX_CIPHERTEXT_LEN = 16384 + 256;
        pub const MAX_CIPHERTEXT_LEN_TLS12 = 16384 + 2048;
        pub const RECORD_HEADER_LEN = 5;
        pub const MAX_HANDSHAKE_LEN = 65536;

        pub const RecordHeader = struct {
            content_type: ContentType,
            legacy_version: ProtocolVersion,
            length: u16,

            pub const SIZE = 5;

            pub fn parse(buf: []const u8) error{BufferTooSmall}!RecordHeader {
                if (buf.len < SIZE) return error.BufferTooSmall;
                return .{
                    .content_type = @enumFromInt(buf[0]),
                    .legacy_version = @enumFromInt(mem.readInt(u16, buf[1..3], .big)),
                    .length = mem.readInt(u16, buf[3..5], .big),
                };
            }

            pub fn serialize(self: RecordHeader, buf: []u8) error{BufferTooSmall}!void {
                if (buf.len < SIZE) return error.BufferTooSmall;
                buf[0] = @intFromEnum(self.content_type);
                mem.writeInt(u16, buf[1..3], @intFromEnum(self.legacy_version), .big);
                mem.writeInt(u16, buf[3..5], self.length, .big);
            }
        };

        pub const HandshakeHeader = struct {
            msg_type: HandshakeType,
            length: u24,

            pub const SIZE = 4;

            pub fn parse(buf: []const u8) error{BufferTooSmall}!HandshakeHeader {
                if (buf.len < SIZE) return error.BufferTooSmall;
                return .{
                    .msg_type = @enumFromInt(buf[0]),
                    .length = mem.readInt(u24, buf[1..4], .big),
                };
            }

            pub fn serialize(self: HandshakeHeader, buf: []u8) error{BufferTooSmall}!void {
                if (buf.len < SIZE) return error.BufferTooSmall;
                buf[0] = @intFromEnum(self.msg_type);
                mem.writeInt(u24, buf[1..4], self.length, .big);
            }
        };
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 0, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;
            const testing = lib.testing;
            const common = make(lib);

            {
                const header = common.RecordHeader{
                    .content_type = .handshake,
                    .legacy_version = .tls_1_2,
                    .length = 512,
                };

                var buf: [common.RecordHeader.SIZE]u8 = undefined;
                try header.serialize(&buf);

                const decoded = try common.RecordHeader.parse(&buf);
                try testing.expectEqual(header.content_type, decoded.content_type);
                try testing.expectEqual(header.legacy_version, decoded.legacy_version);
                try testing.expectEqual(header.length, decoded.length);
            }

            {
                const header = common.HandshakeHeader{
                    .msg_type = .certificate,
                    .length = 0x010203,
                };

                var buf: [common.HandshakeHeader.SIZE]u8 = undefined;
                try header.serialize(&buf);

                const decoded = try common.HandshakeHeader.parse(&buf);
                try testing.expectEqual(header.msg_type, decoded.msg_type);
                try testing.expectEqual(header.length, decoded.length);
            }

            try testing.expect(common.CipherSuite.TLS_AES_128_GCM_SHA256.isTls13());
            try testing.expectEqual(@as(u8, 16), common.CipherSuite.TLS_AES_128_GCM_SHA256.keyLength());
            try testing.expectEqual(@as(u8, 12), common.CipherSuite.TLS_AES_128_GCM_SHA256.ivLength());
            try testing.expectEqual(@as(u8, 16), common.CipherSuite.TLS_AES_128_GCM_SHA256.tagLength());

            try testing.expect(!common.CipherSuite.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256.isTls13());

            try testing.expectEqualStrings("TLS 1.3", common.ProtocolVersion.tls_1_3.name());
        }
    }.run);
}
