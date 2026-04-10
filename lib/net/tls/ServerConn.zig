const NetConn = @import("../Conn.zig");

pub fn ServerConn(comptime lib: type) type {
    const common = @import("common.zig").make(lib);
    const alert = @import("alert.zig").make(lib);
    const kdf = @import("kdf.zig").make(lib);
    const record = @import("record.zig").make(lib);
    const server_handshake = @import("server_handshake.zig").make(lib);
    const Allocator = lib.mem.Allocator;
    const Mutex = lib.Thread.Mutex;

    return struct {
        pub const Config = server_handshake.Config;
        pub const Certificate = server_handshake.Certificate;
        pub const PrivateKey = server_handshake.PrivateKey;
        pub const HandshakeError = server_handshake.HandshakeError;
        pub const HandshakeState = server_handshake.HandshakeState;
        pub const InitError = Allocator.Error || HandshakeError;

        allocator: Allocator,
        inner: NetConn,
        handshake_state: server_handshake.ServerHandshake(NetConn),
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
        write_plaintext_buf: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined,
        plaintext_buf: [common.MAX_CIPHERTEXT_LEN]u8 = undefined,
        handshake_buf: [common.MAX_HANDSHAKE_LEN]u8 = undefined,
        handshake_msg_buf: [common.MAX_HANDSHAKE_LEN]u8 = undefined,
        handshake_msg_len: usize = 0,

        const Self = @This();

        pub fn handshake(self: *Self) HandshakeError!void {
            self.handshake_mu.lock();
            defer self.handshake_mu.unlock();

            if (self.handshake_complete) return;

            while (!self.handshake_complete) {
                const res = self.handshake_state.records.readRecord(&self.read_record_buf, &self.plaintext_buf) catch |err| {
                    return self.mapHandshakeRecordError(err);
                };
                switch (res.content_type) {
                    .handshake => self.consumeHandshakeRecord(self.plaintext_buf[0..res.length]) catch |err| {
                        return self.failHandshake(err);
                    },
                    .change_cipher_spec => {
                        if (self.handshake_msg_len != 0) return self.failHandshake(error.InvalidHandshake);
                        self.handshake_state.processChangeCipherSpec(self.plaintext_buf[0..res.length]) catch |err| {
                            return self.failHandshake(err);
                        };
                        continue;
                    },
                    .alert => {
                        if (self.handshake_msg_len != 0) return self.failHandshake(error.InvalidHandshake);
                        return self.mapAlert(self.plaintext_buf[0..res.length]);
                    },
                    else => return self.failHandshake(error.UnexpectedMessage),
                }

                if (self.handshake_state.shouldSendServerFlight()) {
                    self.handshake_state.sendServerFlight(&self.handshake_buf, &self.write_record_buf) catch |err| {
                        return self.mapHandshakeFlightWriteError(err);
                    };
                }
                if (self.handshake_state.state == .connected) {
                    self.handshake_complete = true;
                }
            }
        }

        pub fn read(self: *Self, buf: []u8) NetConn.ReadError!usize {
            if (buf.len == 0) return 0;
            self.handshake() catch |err| return self.mapHandshakeReadError(err);

            self.read_mu.lock();
            var read_locked = true;
            defer if (read_locked) self.read_mu.unlock();

            if (self.pending_start < self.pending_end) return self.readPending(buf);

            while (true) {
                const res = self.handshake_state.records.readRecord(&self.read_record_buf, &self.plaintext_buf) catch |err| switch (err) {
                    error.TimedOut => return error.TimedOut,
                    error.ConnectionRefused => return error.ConnectionRefused,
                    error.ConnectionReset => return error.ConnectionReset,
                    error.BrokenPipe => return error.BrokenPipe,
                    else => return error.Unexpected,
                };
                switch (res.content_type) {
                    .application_data => {
                        @memcpy(self.pending_plaintext[0..res.length], self.plaintext_buf[0..res.length]);
                        self.pending_start = 0;
                        self.pending_end = res.length;
                        return self.readPending(buf);
                    },
                    .alert => return self.mapReadAlert(self.plaintext_buf[0..res.length]),
                    .change_cipher_spec => return error.Unexpected,
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

        pub fn write(self: *Self, buf: []const u8) NetConn.WriteError!usize {
            self.handshake() catch |err| return self.mapHandshakeWriteError(err);
            if (buf.len == 0) return 0;

            self.write_mu.lock();
            defer self.write_mu.unlock();

            const chunk_len = @min(buf.len, common.MAX_PLAINTEXT_LEN);
            _ = self.handshake_state.records.writeRecord(
                .application_data,
                buf[0..chunk_len],
                &self.write_record_buf,
                &self.write_plaintext_buf,
            ) catch |err| switch (err) {
                error.TimedOut => return error.TimedOut,
                error.ConnectionRefused => return error.ConnectionRefused,
                error.ConnectionReset => return error.ConnectionReset,
                error.BrokenPipe => return error.BrokenPipe,
                else => return error.Unexpected,
            };
            return chunk_len;
        }

        pub fn writeAll(self: *Self, buf: []const u8) NetConn.WriteError!void {
            var written: usize = 0;
            while (written < buf.len) written += try self.write(buf[written..]);
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

        fn consumeHandshakeRecord(self: *Self, data: []const u8) HandshakeError!void {
            try self.appendHandshakeBytes(data);

            var consumed: usize = 0;
            while (self.handshake_msg_len - consumed >= common.HandshakeHeader.SIZE) {
                const header = common.HandshakeHeader.parse(self.handshake_msg_buf[consumed..self.handshake_msg_len]) catch {
                    return error.InvalidHandshake;
                };
                const total_len = common.HandshakeHeader.SIZE + @as(usize, header.length);
                if (total_len > self.handshake_msg_buf.len) return error.BufferTooSmall;
                if (self.handshake_msg_len - consumed < total_len) break;
                try self.handshake_state.processHandshake(self.handshake_msg_buf[consumed .. consumed + total_len]);
                consumed += total_len;
            }

            self.compactHandshakeBytes(consumed);
        }

        fn consumePostHandshake(self: *Self, data: []const u8) NetConn.ReadError!bool {
            self.appendHandshakeBytes(data) catch return error.Unexpected;

            var should_send_key_update = false;
            var consumed: usize = 0;
            while (self.handshake_msg_len - consumed >= common.HandshakeHeader.SIZE) {
                const header = common.HandshakeHeader.parse(self.handshake_msg_buf[consumed..self.handshake_msg_len]) catch {
                    return error.Unexpected;
                };
                const total_len = common.HandshakeHeader.SIZE + header.length;
                if (total_len > self.handshake_msg_buf.len) return error.Unexpected;
                if (self.handshake_msg_len - consumed < total_len) break;

                const payload = self.handshake_msg_buf[consumed + common.HandshakeHeader.SIZE ..][0..header.length];
                switch (header.msg_type) {
                    .key_update => {
                        if (try self.handleKeyUpdate(payload)) should_send_key_update = true;
                    },
                    else => return error.Unexpected,
                }
                consumed += total_len;
            }

            self.compactHandshakeBytes(consumed);
            return should_send_key_update;
        }

        fn appendHandshakeBytes(self: *Self, data: []const u8) error{BufferTooSmall}!void {
            if (data.len > self.handshake_msg_buf.len - self.handshake_msg_len) return error.BufferTooSmall;
            @memcpy(self.handshake_msg_buf[self.handshake_msg_len..][0..data.len], data);
            self.handshake_msg_len += data.len;
        }

        fn compactHandshakeBytes(self: *Self, consumed: usize) void {
            if (consumed == 0) return;
            const remaining = self.handshake_msg_len - consumed;
            var i: usize = 0;
            while (i < remaining) : (i += 1) {
                self.handshake_msg_buf[i] = self.handshake_msg_buf[consumed + i];
            }
            self.handshake_msg_len = remaining;
        }

        fn handleKeyUpdate(self: *Self, payload: []const u8) NetConn.ReadError!bool {
            if (self.handshake_state.version != .tls_1_3) return error.Unexpected;
            if (payload.len != 1 or payload[0] > 1) return error.Unexpected;

            self.handshake_state.client_application_traffic_secret = try nextTrafficSecret(
                self,
                self.handshake_state.client_application_traffic_secret,
            );
            self.handshake_state.records.setReadCipher(
                try self.cipherFromTrafficSecret(self.tls13Secret(&self.handshake_state.client_application_traffic_secret)),
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
                &self.write_plaintext_buf,
            ) catch |err| switch (err) {
                error.TimedOut => return error.TimedOut,
                error.ConnectionRefused => return error.ConnectionRefused,
                error.ConnectionReset => return error.ConnectionReset,
                error.BrokenPipe => return error.BrokenPipe,
                else => return error.Unexpected,
            };

            self.handshake_state.server_application_traffic_secret = try nextTrafficSecret(
                self,
                self.handshake_state.server_application_traffic_secret,
            );
            self.handshake_state.records.setWriteCipher(
                try self.cipherFromTrafficSecret(self.tls13Secret(&self.handshake_state.server_application_traffic_secret)),
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
            return switch (alert.alertToError(parsed.description)) {
                error.CloseNotify => error.RecordIoFailed,
                error.UnexpectedMessage => error.UnexpectedMessage,
                error.BadRecordMac => error.BadRecordMac,
                error.ProtocolVersion => error.UnsupportedVersion,
                error.MissingExtension,
                error.UnsupportedExtension,
                => error.MissingExtension,
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

        fn mapHandshakeRecordError(self: *Self, err: record.RecordError) HandshakeError {
            return switch (err) {
                error.BadRecordMac => self.failHandshake(error.BadRecordMac),
                error.BufferTooSmall,
                error.RecordTooLarge,
                error.DecryptionFailed,
                error.UnexpectedRecord,
                => self.failHandshake(error.InvalidHandshake),

                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionReset => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                error.TimedOut => error.TimedOut,
                else => error.RecordIoFailed,
            };
        }

        fn mapHandshakeFlightWriteError(self: *Self, err: HandshakeError) HandshakeError {
            return switch (err) {
                error.RecordIoFailed,
                error.ConnectionRefused,
                error.ConnectionReset,
                error.BrokenPipe,
                error.TimedOut,
                => err,
                else => self.failHandshake(err),
            };
        }

        fn mapHandshakeReadError(_: *Self, err: HandshakeError) NetConn.ReadError {
            return switch (err) {
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionReset => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                error.TimedOut => error.TimedOut,
                else => error.Unexpected,
            };
        }

        fn mapHandshakeWriteError(_: *Self, err: HandshakeError) NetConn.WriteError {
            return switch (err) {
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionReset => error.ConnectionReset,
                error.BrokenPipe => error.BrokenPipe,
                error.TimedOut => error.TimedOut,
                else => error.Unexpected,
            };
        }

        fn sendCloseNotify(self: *Self) void {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.handshake_state.records.sendAlert(.warning, .close_notify, &self.write_record_buf, &self.write_plaintext_buf) catch {};
        }

        fn sendFatalAlert(self: *Self, description: common.AlertDescription) void {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.handshake_state.records.sendAlert(.fatal, description, &self.write_record_buf, &self.write_plaintext_buf) catch {};
        }

        fn handshakeErrorToAlert(err: HandshakeError) common.AlertDescription {
            return switch (err) {
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
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .inner = inner,
                .handshake_state = try server_handshake.ServerHandshake(NetConn).init(inner, config),
            };
            return NetConn.init(self);
        }

        pub fn validateConfig(config: Config) HandshakeError!void {
            try server_handshake.ServerHandshake(NetConn).validateConfig(config);
        }
    };
}
const testing_api = @import("testing");

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, _: lib.mem.Allocator) !void {
            const testing = lib.testing;
            {
                const ServerConnType = ServerConn(lib);
                const record = @import("record.zig").make(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const RawConn = struct {
                    fail_writes: bool = false,
                
                    pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return error.EndOfStream;
                    }
                
                    pub fn write(self: *@This(), _: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        if (self.fail_writes) return error.ConnectionRefused;
                        return 0;
                    }
                
                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };
                
                const key = [_]u8{0x33} ** 16;
                const iv = [_]u8{0x44} ** 12;
                
                var raw = RawConn{ .fail_writes = true };
                var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });
                defer conn.deinit();
                
                const typed = try conn.as(ServerConnType);
                typed.handshake_complete = true;
                typed.handshake_state.state = ServerConnType.HandshakeState.connected;
                typed.handshake_state.records.setVersion(.tls_1_3);
                typed.handshake_state.records.setWriteCipher(try record.CipherState().init(.TLS_AES_128_GCM_SHA256, &key, &iv));
                
                try testing.expectError(error.ConnectionRefused, conn.write("pong"));
            }

            {
                const ServerConnType = ServerConn(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const RawConn = struct {
                    pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return error.TimedOut;
                    }
                
                    pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return 0;
                    }
                
                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };
                
                var raw = RawConn{};
                var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });
                defer conn.deinit();
                
                var buf: [8]u8 = undefined;
                try testing.expectError(error.TimedOut, conn.read(&buf));
            }

            {
                const ServerConnType = ServerConn(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const Helper = struct {
                    fn expectReadError(comptime expected: anyerror) !void {
                        const RawConn = struct {
                            pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                                return expected;
                            }
                
                            pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                                return 0;
                            }
                
                            pub fn close(_: *@This()) void {}
                            pub fn deinit(_: *@This()) void {}
                            pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                            pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                        };
                
                        var raw = RawConn{};
                        var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                            .certificates = &.{.{
                                .chain = &.{fixtures.self_signed_cert_der[0..]},
                                .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                            }},
                        });
                        defer conn.deinit();
                
                        const typed = try conn.as(ServerConnType);
                        typed.handshake_complete = true;
                        typed.handshake_state.state = ServerConnType.HandshakeState.connected;
                
                        var buf: [8]u8 = undefined;
                        try testing.expectError(expected, conn.read(&buf));
                    }
                };
                
                inline for (.{ error.ConnectionRefused, error.ConnectionReset, error.BrokenPipe, error.TimedOut }) |expected| {
                    try Helper.expectReadError(expected);
                }
            }

            {
                const ServerConnType = ServerConn(lib);
                const C = @import("common.zig").make(lib);
                const R = @import("record.zig").make(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const RawConn = struct {
                    read_buf: [C.RecordHeader.SIZE + C.MAX_CIPHERTEXT_LEN]u8 = undefined,
                    read_len: usize = 0,
                    read_pos: usize = 0,
                
                    pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        if (self.read_pos >= self.read_len) return error.EndOfStream;
                        const n = @min(buf.len, self.read_len - self.read_pos);
                        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
                        self.read_pos += n;
                        return n;
                    }
                
                    pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return 0;
                    }
                
                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };
                
                const key = [_]u8{0x77} ** 16;
                const iv = [_]u8{0x88} ** 12;
                const payload_len = C.MAX_PLAINTEXT_LEN;
                const padding_len = 1;
                const ciphertext_len = payload_len + 1 + padding_len;
                
                var raw = RawConn{};
                const header = C.RecordHeader{
                    .content_type = .application_data,
                    .legacy_version = .tls_1_2,
                    .length = @intCast(ciphertext_len + 16),
                };
                try header.serialize(raw.read_buf[0..C.RecordHeader.SIZE]);
                
                var inner_plaintext: [C.MAX_PLAINTEXT_LEN + 2]u8 = undefined;
                @memset(inner_plaintext[0..payload_len], 'b');
                inner_plaintext[payload_len] = @intFromEnum(C.ContentType.application_data);
                inner_plaintext[payload_len + 1] = 0;
                
                var tag: [16]u8 = undefined;
                const cipher = try R.CipherState().init(.TLS_AES_128_GCM_SHA256, &key, &iv);
                switch (cipher) {
                    .aes_128_gcm => |state| state.encrypt(
                        raw.read_buf[C.RecordHeader.SIZE..][0..ciphertext_len],
                        &tag,
                        inner_plaintext[0..ciphertext_len],
                        raw.read_buf[0..C.RecordHeader.SIZE],
                        0,
                    ),
                    else => unreachable,
                }
                @memcpy(raw.read_buf[C.RecordHeader.SIZE + ciphertext_len ..][0..16], &tag);
                raw.read_len = C.RecordHeader.SIZE + ciphertext_len + 16;
                
                var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });
                defer conn.deinit();
                
                const typed = try conn.as(ServerConnType);
                typed.handshake_complete = true;
                typed.handshake_state.state = ServerConnType.HandshakeState.connected;
                typed.handshake_state.records.setVersion(.tls_1_3);
                typed.handshake_state.records.setReadCipher(try R.CipherState().init(.TLS_AES_128_GCM_SHA256, &key, &iv));
                
                var buf: [1]u8 = undefined;
                try testing.expectEqual(@as(usize, 1), try conn.read(&buf));
                try testing.expectEqual(@as(u8, 'b'), buf[0]);
            }

            {
                const ServerConnType = ServerConn(lib);
                const common = @import("common.zig").make(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const Helper = struct {
                    const RawConn = struct {
                        read_buf: [256]u8 = undefined,
                        read_len: usize = 0,
                        read_pos: usize = 0,
                        write_calls: usize = 0,
                
                        pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                            if (self.read_pos >= self.read_len) return error.EndOfStream;
                            const n = @min(buf.len, self.read_len - self.read_pos);
                            @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
                            self.read_pos += n;
                            return n;
                        }
                
                        pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                            self.write_calls += 1;
                            return buf.len;
                        }
                
                        pub fn close(_: *@This()) void {}
                        pub fn deinit(_: *@This()) void {}
                        pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                        pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                    };
                
                    fn appendAlert(raw: *RawConn, level: common.AlertLevel, description: common.AlertDescription) void {
                        raw.read_len = 7;
                        raw.read_pos = 0;
                        raw.read_buf[0] = @intFromEnum(common.ContentType.alert);
                        raw.read_buf[1] = 0x03;
                        raw.read_buf[2] = 0x03;
                        raw.read_buf[3] = 0x00;
                        raw.read_buf[4] = 0x02;
                        raw.read_buf[5] = @intFromEnum(level);
                        raw.read_buf[6] = @intFromEnum(description);
                    }
                
                    fn expectPeerAlert(comptime description: common.AlertDescription, comptime expected: anyerror) !void {
                        var raw = RawConn{};
                        appendAlert(&raw, .fatal, description);
                
                        var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                            .certificates = &.{.{
                                .chain = &.{fixtures.self_signed_cert_der[0..]},
                                .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                            }},
                        });
                        defer conn.deinit();
                
                        const typed = try conn.as(ServerConnType);
                        try testing.expectError(expected, typed.handshake());
                        try testing.expectEqual(@as(usize, 0), raw.write_calls);
                    }
                };
                
                try Helper.expectPeerAlert(.close_notify, error.RecordIoFailed);
                try Helper.expectPeerAlert(.bad_record_mac, error.BadRecordMac);
                try Helper.expectPeerAlert(.protocol_version, error.UnsupportedVersion);
            }

            {
                const ServerConnType = ServerConn(lib);
                const common = @import("common.zig").make(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const RawConn = struct {
                    read_buf: [8]u8 = undefined,
                    read_len: usize = 0,
                    read_pos: usize = 0,
                    write_calls: usize = 0,
                
                    pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        if (self.read_pos >= self.read_len) return error.EndOfStream;
                        const n = @min(buf.len, self.read_len - self.read_pos);
                        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
                        self.read_pos += n;
                        return n;
                    }
                
                    pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        self.write_calls += 1;
                        return buf.len;
                    }
                
                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };
                
                var raw = RawConn{};
                raw.read_len = common.RecordHeader.SIZE;
                raw.read_buf[0] = @intFromEnum(common.ContentType.handshake);
                raw.read_buf[1] = 0x03;
                raw.read_buf[2] = 0x03;
                raw.read_buf[3] = 0x00;
                raw.read_buf[4] = 0x03;
                
                var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });
                defer conn.deinit();
                
                const typed = try conn.as(ServerConnType);
                try testing.expectError(error.InvalidHandshake, typed.handshake());
                try testing.expectEqual(@as(usize, 1), raw.write_calls);
            }

            {
                const ServerConnType = ServerConn(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const RawConn = struct {
                    write_calls: usize = 0,
                
                    pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return error.EndOfStream;
                    }
                
                    pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        self.write_calls += 1;
                        return buf.len;
                    }
                
                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };
                
                var raw = RawConn{};
                var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });
                defer conn.deinit();
                
                const typed = try conn.as(ServerConnType);
                typed.handshake_state.state = .send_server_flight;
                
                try testing.expectEqual(error.RecordIoFailed, typed.mapHandshakeFlightWriteError(error.RecordIoFailed));
                inline for (.{ error.ConnectionRefused, error.ConnectionReset, error.BrokenPipe, error.TimedOut }) |expected| {
                    try testing.expectEqual(expected, typed.mapHandshakeFlightWriteError(expected));
                }
                try testing.expectEqual(@as(usize, 0), raw.write_calls);
            }

            {
                const ServerConnType = ServerConn(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const RawConn = struct {
                    write_calls: usize = 0,
                
                    pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return error.EndOfStream;
                    }
                
                    pub fn write(self: *@This(), buf: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        self.write_calls += 1;
                        return buf.len;
                    }
                
                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };
                
                var raw = RawConn{};
                var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });
                defer conn.deinit();
                
                const typed = try conn.as(ServerConnType);
                typed.handshake_state.state = .send_server_flight;
                
                try testing.expectEqual(error.BufferTooSmall, typed.mapHandshakeFlightWriteError(error.BufferTooSmall));
                try testing.expectEqual(@as(usize, 1), raw.write_calls);
            }

            {
                const ServerConnType = ServerConn(lib);
                const CH = @import("client_handshake.zig").make(lib);
                const SH = @import("server_handshake.zig").make(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const RawConn = struct {
                    pub fn read(_: *@This(), _: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return error.EndOfStream;
                    }
                
                    pub fn write(_: *@This(), buf: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return buf.len;
                    }
                
                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };
                
                var client_raw = RawConn{};
                var client_hs = try CH.ClientHandshake(NetConn).init(NetConn.init(&client_raw), "example.com", testing.allocator, true);
                var hello_buf: [4096]u8 = undefined;
                const hello_len = try client_hs.encodeClientHello(&hello_buf);
                
                var raw = RawConn{};
                var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });
                defer conn.deinit();
                
                const typed = try conn.as(ServerConnType);
                typed.handshake_state.state = .wait_client_hello;
                
                const split = 32;
                try typed.consumeHandshakeRecord(hello_buf[0..split]);
                try testing.expectEqual(@as(usize, split), typed.handshake_msg_len);
                try testing.expectEqual(SH.HandshakeState.wait_client_hello, typed.handshake_state.state);
                
                try typed.consumeHandshakeRecord(hello_buf[split..hello_len]);
                try testing.expectEqual(@as(usize, 0), typed.handshake_msg_len);
                try testing.expectEqual(SH.HandshakeState.send_server_flight, typed.handshake_state.state);
            }

            {
                const ServerConnType = ServerConn(lib);
                const C = @import("common.zig").make(lib);
                const SH = @import("server_handshake.zig").make(lib);
                const fixtures = @import("test_fixtures.zig");
                
                const RawConn = struct {
                    read_buf: [16]u8 = undefined,
                    read_len: usize = 0,
                    read_pos: usize = 0,
                
                    pub fn read(self: *@This(), buf: []u8) error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        if (self.read_pos >= self.read_len) return error.EndOfStream;
                        const n = @min(buf.len, self.read_len - self.read_pos);
                        @memcpy(buf[0..n], self.read_buf[self.read_pos..][0..n]);
                        self.read_pos += n;
                        return n;
                    }
                
                    pub fn write(_: *@This(), _: []const u8) error{ ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected }!usize {
                        return 0;
                    }
                
                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };
                
                var raw = RawConn{};
                raw.read_len = 6;
                raw.read_buf[0] = @intFromEnum(C.ContentType.change_cipher_spec);
                raw.read_buf[1] = 0x03;
                raw.read_buf[2] = 0x03;
                raw.read_buf[3] = 0x00;
                raw.read_buf[4] = 0x01;
                raw.read_buf[5] = @intFromEnum(C.ChangeCipherSpecType.change_cipher_spec);
                
                var conn = try ServerConnType.init(testing.allocator, NetConn.init(&raw), .{
                    .certificates = &.{.{
                        .chain = &.{fixtures.self_signed_cert_der[0..]},
                        .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                    }},
                });
                defer conn.deinit();
                
                const typed = try conn.as(ServerConnType);
                typed.handshake_complete = true;
                typed.handshake_state.state = SH.HandshakeState.connected;
                
                var buf: [8]u8 = undefined;
                try testing.expectError(error.Unexpected, conn.read(&buf));
            }

        }
    }.run);
}