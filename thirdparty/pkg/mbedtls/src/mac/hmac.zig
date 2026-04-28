const shared = @import("../shared.zig");

const mbedtls = shared.mbedtls;
const psa = mbedtls.psa;

pub const HmacSha256 = HmacImpl(.sha256);
pub const HmacSha384 = HmacImpl(.sha384);
pub const HmacSha512 = HmacImpl(.sha512);

fn HmacImpl(comptime mode: enum { sha256, sha384, sha512 }) type {
    return struct {
        pub const mac_length = switch (mode) {
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
        };
        pub const key_length = 32;
        pub const key_length_min = 0;

        key: psa.Key,
        op: psa.mac.Operation,
        active: bool = true,

        const Self = @This();

        pub fn create(out: *[mac_length]u8, msg: []const u8, key: []const u8) void {
            var self = init(key);
            defer self.deinit();
            self.update(msg);
            self.final(out);
        }

        pub fn init(key: []const u8) Self {
            shared.psa_mutex.lock();
            defer shared.psa_mutex.unlock();

            var attrs = psa.KeyAttributes.init();
            defer attrs.deinit();
            attrs.setType(psa.types.key_type.hmac);
            attrs.setBits(8 * key.len);
            attrs.setUsage(psa.types.usage.sign_message);
            attrs.setAlgorithm(psa.types.alg.hmac(hashAlg()));

            var psa_key = psa.Key.import(&attrs, key) catch @panic("mbedTLS HMAC key import failed");
            const op = psa.mac.Operation.signSetup(psa_key, psa.types.alg.hmac(hashAlg())) catch {
                psa_key.deinit();
                @panic("mbedTLS HMAC setup failed");
            };
            return .{ .key = psa_key, .op = op };
        }

        pub fn update(self: *Self, msg: []const u8) void {
            if (!self.active) @panic("mbedTLS HMAC context is not active");
            shared.psa_mutex.lock();
            defer shared.psa_mutex.unlock();
            self.op.update(msg) catch @panic("mbedTLS HMAC update failed");
        }

        pub fn final(self: *Self, out: *[mac_length]u8) void {
            if (!self.active) @panic("mbedTLS HMAC context is not active");
            shared.psa_mutex.lock();
            defer shared.psa_mutex.unlock();
            const result = self.op.signFinish(out) catch {
                self.key.deinit();
                self.active = false;
                @panic("mbedTLS HMAC finish failed");
            };
            self.key.deinit();
            self.active = false;
            if (result.len != mac_length) @panic("mbedTLS HMAC length mismatch");
        }

        pub fn deinit(self: *Self) void {
            if (!self.active) return;
            shared.psa_mutex.lock();
            defer shared.psa_mutex.unlock();
            self.op.abort();
            self.key.deinit();
            self.active = false;
        }

        fn hashAlg() psa.types.Algorithm {
            return switch (mode) {
                .sha256 => psa.types.alg.sha256,
                .sha384 => psa.types.alg.sha384,
                .sha512 => psa.types.alg.sha512,
            };
        }
    };
}
