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
        plaintext_buf: [common.MAX_PLAINTEXT_LEN + 1]u8 = undefined,
        handshake_buf: [common.MAX_HANDSHAKE_LEN]u8 = undefined,

        const Self = @This();

        pub fn handshake(self: *Self) HandshakeError!void {
            self.handshake_mu.lock();
            defer self.handshake_mu.unlock();

            if (self.handshake_complete) return;

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

                if (self.handshake_state.shouldSendServerFlight()) {
                    self.handshake_state.sendServerFlight(&self.handshake_buf, &self.write_record_buf) catch |err| {
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

            if (self.pending_start < self.pending_end) return self.readPending(buf);

            while (true) {
                const res = self.handshake_state.records.readRecord(&self.read_record_buf, &self.plaintext_buf) catch |err| switch (err) {
                    error.TimedOut => return error.TimedOut,
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

        pub fn write(self: *Self, buf: []const u8) NetConn.WriteError!usize {
            self.handshake() catch return error.Unexpected;
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

                const payload = data[pos + common.HandshakeHeader.SIZE ..][0..header.length];
                switch (header.msg_type) {
                    .key_update => {
                        if (try self.handleKeyUpdate(payload)) should_send_key_update = true;
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
            return switch (parsed.description) {
                .bad_record_mac => error.BadRecordMac,
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
