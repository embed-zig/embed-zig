const shared = @import("../shared.zig");
const random_mod = @import("../random.zig");

const mbedtls = shared.mbedtls;
const errors = shared.errors;
const random = random_mod.random;

pub const X25519 = struct {
    pub const bytes_len = 32;
    pub const secret_length = bytes_len;
    pub const public_length = bytes_len;
    pub const shared_length = bytes_len;
    pub const seed_length = bytes_len;
    pub const base_point: [bytes_len]u8 = .{9} ++ .{0} ** (bytes_len - 1);

    pub const KeyPair = struct {
        public_key: [public_length]u8,
        secret_key: [secret_length]u8,

        pub fn generateDeterministic(seed: [seed_length]u8) errors.IdentityElementError!KeyPair {
            return .{
                .public_key = try recoverPublicKey(seed),
                .secret_key = seed,
            };
        }

        pub fn generate() KeyPair {
            while (true) {
                var seed: [seed_length]u8 = undefined;
                random.bytes(&seed);
                return generateDeterministic(seed) catch continue;
            }
        }
    };

    pub fn recoverPublicKey(secret_key: [secret_length]u8) errors.IdentityElementError![public_length]u8 {
        shared.psa_mutex.lock();
        defer shared.psa_mutex.unlock();
        var key = importSecret(secret_key, mbedtls.psa.types.usage.export_key) catch return error.IdentityElement;
        defer key.deinit();
        var out: [public_length]u8 = undefined;
        const public = key.exportPublic(&out) catch return error.IdentityElement;
        if (public.len != public_length) return error.IdentityElement;
        return out;
    }

    pub fn scalarmult(secret_key: [secret_length]u8, public_key: [public_length]u8) errors.IdentityElementError![shared_length]u8 {
        shared.psa_mutex.lock();
        defer shared.psa_mutex.unlock();
        var key = importSecret(secret_key, mbedtls.psa.types.usage.derive) catch return error.IdentityElement;
        defer key.deinit();
        var out: [shared_length]u8 = undefined;
        const result = key.rawAgreement(mbedtls.psa.types.alg.ecdh, &public_key, &out) catch return error.IdentityElement;
        if (result.len != shared_length) return error.IdentityElement;
        return out;
    }

    pub fn scalarmultBase(secret_key: [secret_length]u8) errors.IdentityElementError![shared_length]u8 {
        return recoverPublicKey(secret_key);
    }

    fn importSecret(secret_key: [secret_length]u8, usage: mbedtls.psa.types.Usage) mbedtls.Error!mbedtls.psa.key.Key {
        var attrs = mbedtls.psa.key.KeyAttributes.init();
        defer attrs.deinit();
        attrs.setType(mbedtls.psa.types.key_type.eccKeyPair(mbedtls.psa.types.ecc_family.montgomery));
        attrs.setBits(255);
        attrs.setUsage(usage);
        attrs.setAlgorithm(mbedtls.psa.types.alg.ecdh);
        return mbedtls.psa.key.Key.import(&attrs, &secret_key);
    }
};
