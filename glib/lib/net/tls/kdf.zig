const testing_api = @import("testing");

pub fn make(comptime lib: type) type {
    const common = @import("common.zig").make(lib);
    const crypto = lib.crypto;
    const debug = lib.debug;
    const mem = lib.mem;

    return struct {
        pub const HkdfSha256 = crypto.kdf.hkdf.HkdfSha256;
        pub const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
        pub const HmacSha384 = crypto.auth.hmac.sha2.HmacSha384;
        pub const HkdfSha384 = crypto.kdf.hkdf.Hkdf(HmacSha384);
        pub const Sha256 = crypto.hash.sha2.Sha256;
        pub const Sha384 = crypto.hash.sha2.Sha384;
        pub const MAX_TLS13_SECRET_LEN = HkdfSha384.prk_length;
        pub const MAX_TLS13_DIGEST_LEN = Sha384.digest_length;

        pub fn TranscriptHash(comptime Hash: type) type {
            return struct {
                hasher: Hash,

                const Self = @This();

                pub fn init() Self {
                    return .{ .hasher = Hash.init(.{}) };
                }

                pub fn update(self: *Self, data: []const u8) void {
                    self.hasher.update(data);
                }

                pub fn peek(self: *Self) [Hash.digest_length]u8 {
                    return self.hasher.peek();
                }

                pub fn final(self: *Self) [Hash.digest_length]u8 {
                    return self.hasher.finalResult();
                }

                pub fn reset(self: *Self) void {
                    self.* = init();
                }
            };
        }

        pub const TranscriptPair = struct {
            sha256: TranscriptHash(Sha256),
            sha384: TranscriptHash(Sha384),

            const Self = @This();

            pub fn init() Self {
                return .{
                    .sha256 = TranscriptHash(Sha256).init(),
                    .sha384 = TranscriptHash(Sha384).init(),
                };
            }

            pub fn update(self: *Self, data: []const u8) void {
                self.sha256.update(data);
                self.sha384.update(data);
            }

            pub fn reset(self: *Self) void {
                self.* = init();
            }

            pub fn peekSha256(self: *Self) [Sha256.digest_length]u8 {
                return self.sha256.peek();
            }

            pub fn peekSha384(self: *Self) [Sha384.digest_length]u8 {
                return self.sha384.peek();
            }

            pub fn peekByHash(
                self: *Self,
                hash: common.Tls13Hash,
                out: *[MAX_TLS13_DIGEST_LEN]u8,
            ) []const u8 {
                switch (hash) {
                    .sha256 => {
                        const digest = self.sha256.peek();
                        return copyDigest(out, &digest);
                    },
                    .sha384 => {
                        const digest = self.sha384.peek();
                        return copyDigest(out, &digest);
                    },
                }
            }
        };

        /// HKDF-Expand-Label for TLS 1.3 (RFC 8446 §7.1).
        pub fn hkdfExpandLabel(
            comptime Hkdf: type,
            secret: [Hkdf.prk_length]u8,
            comptime label: []const u8,
            context: []const u8,
            comptime len: usize,
        ) [len]u8 {
            var out: [len]u8 = undefined;
            hkdfExpandLabelInto(Hkdf, &out, secret, label, context);
            return out;
        }

        pub fn hkdfExpandLabelInto(
            comptime Hkdf: type,
            out: []u8,
            secret: [Hkdf.prk_length]u8,
            comptime label: []const u8,
            context: []const u8,
        ) void {
            const full_label = "tls13 " ++ label;
            comptime {
                if (full_label.len > 255) @compileError("TLS 1.3 HKDF label is too long");
            }
            debug.assert(context.len <= 255);

            var hkdf_label: [2 + 1 + full_label.len + 1 + 255]u8 = undefined;
            var pos: usize = 0;

            mem.writeInt(u16, hkdf_label[pos..][0..2], @intCast(out.len), .big);
            pos += 2;

            hkdf_label[pos] = @intCast(full_label.len);
            pos += 1;
            @memcpy(hkdf_label[pos..][0..full_label.len], full_label);
            pos += full_label.len;

            hkdf_label[pos] = @intCast(context.len);
            pos += 1;
            if (context.len != 0) {
                @memcpy(hkdf_label[pos..][0..context.len], context);
                pos += context.len;
            }

            Hkdf.expand(out, hkdf_label[0..pos], secret);
        }

        pub fn hkdfExpandLabelSha256(
            secret: [HkdfSha256.prk_length]u8,
            comptime label: []const u8,
            context: []const u8,
            comptime len: usize,
        ) [len]u8 {
            return hkdfExpandLabel(HkdfSha256, secret, label, context, len);
        }

        pub fn hkdfExpandLabelSha384(
            secret: [HkdfSha384.prk_length]u8,
            comptime label: []const u8,
            context: []const u8,
            comptime len: usize,
        ) [len]u8 {
            return hkdfExpandLabel(HkdfSha384, secret, label, context, len);
        }

        pub fn deriveSecret(
            comptime Hkdf: type,
            secret: [Hkdf.prk_length]u8,
            comptime label: []const u8,
            transcript_hash: []const u8,
        ) [Hkdf.prk_length]u8 {
            return hkdfExpandLabel(Hkdf, secret, label, transcript_hash, Hkdf.prk_length);
        }

        pub fn deriveSecretSha256(
            secret: [HkdfSha256.prk_length]u8,
            comptime label: []const u8,
            transcript_hash: []const u8,
        ) [HkdfSha256.prk_length]u8 {
            return deriveSecret(HkdfSha256, secret, label, transcript_hash);
        }

        pub fn deriveSecretSha384(
            secret: [HkdfSha384.prk_length]u8,
            comptime label: []const u8,
            transcript_hash: []const u8,
        ) [HkdfSha384.prk_length]u8 {
            return deriveSecret(HkdfSha384, secret, label, transcript_hash);
        }

        pub fn finishedKey(comptime Hkdf: type, traffic_secret: [Hkdf.prk_length]u8) [Hkdf.prk_length]u8 {
            return hkdfExpandLabel(Hkdf, traffic_secret, "finished", "", Hkdf.prk_length);
        }

        pub fn finishedKeySha256(traffic_secret: [HkdfSha256.prk_length]u8) [HkdfSha256.prk_length]u8 {
            return finishedKey(HkdfSha256, traffic_secret);
        }

        pub fn finishedKeySha384(traffic_secret: [HkdfSha384.prk_length]u8) [HkdfSha384.prk_length]u8 {
            return finishedKey(HkdfSha384, traffic_secret);
        }

        pub fn finishedVerifyData(
            comptime Hkdf: type,
            comptime Hmac: type,
            traffic_secret: [Hkdf.prk_length]u8,
            transcript_hash: []const u8,
        ) [Hmac.mac_length]u8 {
            const key = finishedKey(Hkdf, traffic_secret);
            var out: [Hmac.mac_length]u8 = undefined;
            Hmac.create(&out, transcript_hash, &key);
            return out;
        }

        pub fn finishedVerifyDataSha256(
            traffic_secret: [HkdfSha256.prk_length]u8,
            transcript_hash: []const u8,
        ) [HmacSha256.mac_length]u8 {
            return finishedVerifyData(HkdfSha256, HmacSha256, traffic_secret, transcript_hash);
        }

        pub fn finishedVerifyDataSha384(
            traffic_secret: [HkdfSha384.prk_length]u8,
            transcript_hash: []const u8,
        ) [HmacSha384.mac_length]u8 {
            return finishedVerifyData(HkdfSha384, HmacSha384, traffic_secret, transcript_hash);
        }

        pub fn hkdfExtractProfile(
            profile: common.Tls13CipherProfile,
            out: *[MAX_TLS13_SECRET_LEN]u8,
            salt: []const u8,
            ikm: []const u8,
        ) []const u8 {
            return switch (profile.hash) {
                .sha256 => {
                    const prk = HkdfSha256.extract(salt, ikm);
                    return copySecret(out, &prk);
                },
                .sha384 => {
                    const prk = HkdfSha384.extract(salt, ikm);
                    return copySecret(out, &prk);
                },
            };
        }

        pub fn hkdfExpandLabelIntoProfile(
            profile: common.Tls13CipherProfile,
            out: []u8,
            secret: []const u8,
            comptime label: []const u8,
            context: []const u8,
        ) void {
            switch (profile.hash) {
                .sha256 => {
                    debug.assert(secret.len == HkdfSha256.prk_length);
                    var prk: [HkdfSha256.prk_length]u8 = undefined;
                    @memcpy(prk[0..], secret);
                    hkdfExpandLabelInto(HkdfSha256, out, prk, label, context);
                },
                .sha384 => {
                    debug.assert(secret.len == HkdfSha384.prk_length);
                    var prk: [HkdfSha384.prk_length]u8 = undefined;
                    @memcpy(prk[0..], secret);
                    hkdfExpandLabelInto(HkdfSha384, out, prk, label, context);
                },
            }
        }

        pub fn deriveSecretProfile(
            profile: common.Tls13CipherProfile,
            out: *[MAX_TLS13_SECRET_LEN]u8,
            secret: []const u8,
            comptime label: []const u8,
            transcript_hash: []const u8,
        ) []const u8 {
            const len = profile.secretLength();
            hkdfExpandLabelIntoProfile(profile, out[0..len], secret, label, transcript_hash);
            if (len < out.len) @memset(out[len..], 0);
            return out[0..len];
        }

        pub fn finishedVerifyDataProfile(
            profile: common.Tls13CipherProfile,
            out: *[MAX_TLS13_DIGEST_LEN]u8,
            traffic_secret: []const u8,
            transcript_hash: []const u8,
        ) []const u8 {
            return switch (profile.hash) {
                .sha256 => {
                    debug.assert(traffic_secret.len == HkdfSha256.prk_length);
                    var secret: [HkdfSha256.prk_length]u8 = undefined;
                    @memcpy(secret[0..], traffic_secret);
                    const verify = finishedVerifyDataSha256(secret, transcript_hash);
                    return copyDigest(out, &verify);
                },
                .sha384 => {
                    debug.assert(traffic_secret.len == HkdfSha384.prk_length);
                    var secret: [HkdfSha384.prk_length]u8 = undefined;
                    @memcpy(secret[0..], traffic_secret);
                    const verify = finishedVerifyDataSha384(secret, transcript_hash);
                    return copyDigest(out, &verify);
                },
            };
        }

        pub fn emptyHash(
            profile: common.Tls13CipherProfile,
            out: *[MAX_TLS13_DIGEST_LEN]u8,
        ) []const u8 {
            return switch (profile.hash) {
                .sha256 => {
                    var digest: [Sha256.digest_length]u8 = undefined;
                    Sha256.hash("", &digest, .{});
                    return copyDigest(out, &digest);
                },
                .sha384 => {
                    var digest: [Sha384.digest_length]u8 = undefined;
                    Sha384.hash("", &digest, .{});
                    return copyDigest(out, &digest);
                },
            };
        }

        /// TLS 1.2 PRF using the selected HMAC hash.
        pub fn tls12Prf(
            comptime Hmac: type,
            out: []u8,
            secret: []const u8,
            label: []const u8,
            seed: []const u8,
        ) void {
            var label_seed: [256]u8 = undefined;
            debug.assert(label.len + seed.len <= label_seed.len);

            @memcpy(label_seed[0..label.len], label);
            @memcpy(label_seed[label.len..][0..seed.len], seed);
            const ls = label_seed[0 .. label.len + seed.len];

            var a: [Hmac.mac_length]u8 = undefined;
            Hmac.create(&a, ls, secret);

            var pos: usize = 0;
            while (pos < out.len) {
                var ctx = Hmac.init(secret);
                ctx.update(&a);
                ctx.update(ls);

                var block: [Hmac.mac_length]u8 = undefined;
                ctx.final(&block);

                const copy_len = @min(block.len, out.len - pos);
                @memcpy(out[pos..][0..copy_len], block[0..copy_len]);
                pos += copy_len;

                Hmac.create(&a, &a, secret);
            }
        }

        pub fn tls12PrfSha256(out: []u8, secret: []const u8, label: []const u8, seed: []const u8) void {
            tls12Prf(HmacSha256, out, secret, label, seed);
        }

        fn copySecret(out: *[MAX_TLS13_SECRET_LEN]u8, secret: []const u8) []const u8 {
            @memset(out, 0);
            @memcpy(out[0..secret.len], secret);
            return out[0..secret.len];
        }

        fn copyDigest(out: *[MAX_TLS13_DIGEST_LEN]u8, digest: []const u8) []const u8 {
            @memset(out, 0);
            @memcpy(out[0..digest.len], digest);
            return out[0..digest.len];
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;
            const testing = lib.testing;
            const K = make(lib);

            {
                const secret: [K.HkdfSha256.prk_length]u8 = [_]u8{0x01} ** K.HkdfSha256.prk_length;
                const result = K.hkdfExpandLabelSha256(secret, "key", "", 16);
                try testing.expectEqual(@as(usize, 16), result.len);
            }

            {
                const secret: [K.HkdfSha256.prk_length]u8 = [_]u8{0x05} ** K.HkdfSha256.prk_length;
                const r1 = K.hkdfExpandLabelSha256(secret, "key", "", 16);
                const r2 = K.hkdfExpandLabelSha256(secret, "key", "", 16);
                try testing.expectEqualSlices(u8, &r1, &r2);
            }

            {
                const secret: [K.HkdfSha256.prk_length]u8 = [_]u8{0x11} ** K.HkdfSha256.prk_length;
                const transcript: [K.Sha256.digest_length]u8 = [_]u8{0x22} ** K.Sha256.digest_length;

                const c_hs = K.deriveSecretSha256(secret, "c hs traffic", &transcript);
                const s_hs = K.deriveSecretSha256(secret, "s hs traffic", &transcript);
                try testing.expect(!lib.mem.eql(u8, &c_hs, &s_hs));
            }

            {
                const secret: [K.HkdfSha256.prk_length]u8 = [_]u8{0x33} ** K.HkdfSha256.prk_length;
                const transcript: [K.Sha256.digest_length]u8 = [_]u8{0x44} ** K.Sha256.digest_length;

                const v1 = K.finishedVerifyDataSha256(secret, &transcript);
                const v2 = K.finishedVerifyDataSha256(secret, &transcript);
                try testing.expectEqualSlices(u8, &v1, &v2);
            }

            {
                var out: [48]u8 = undefined;
                K.tls12PrfSha256(&out, "pre-master-secret", "master secret", "seed");
                try testing.expect(!lib.mem.allEqual(u8, &out, 0));
            }

            {
                var tx = K.TranscriptHash(K.Sha256).init();
                tx.update("hel");
                const peeked = tx.peek();
                tx.update("lo");
                const finaled = tx.final();

                var expected: [K.Sha256.digest_length]u8 = undefined;
                K.Sha256.hash("hello", &expected, .{});

                try testing.expect(!lib.mem.eql(u8, &peeked, &expected));
                try testing.expectEqualSlices(u8, &expected, &finaled);
            }

        }
    }.run);
}
