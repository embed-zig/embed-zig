const shared = @import("../shared.zig");

const c = shared.c;
const errors = shared.errors;
const checkMbed = shared.checkMbed;

pub const Aes128Gcm = AesGcmImpl(16);
pub const Aes256Gcm = AesGcmImpl(32);

fn AesGcmImpl(comptime key_len: usize) type {
    return struct {
        pub const tag_length = 16;
        pub const nonce_length = 12;
        pub const key_length = key_len;

        pub fn encrypt(ciphertext: []u8, tag: *[tag_length]u8, plaintext: []const u8, aad: []const u8, nonce: [nonce_length]u8, key: [key_length]u8) void {
            var ctx: c.mbedtls_gcm_context = undefined;
            c.mbedtls_gcm_init(&ctx);
            defer c.mbedtls_gcm_free(&ctx);
            checkMbed(c.mbedtls_gcm_setkey(&ctx, c.MBEDTLS_CIPHER_ID_AES, &key, key_length * 8));
            checkMbed(c.mbedtls_gcm_crypt_and_tag(&ctx, c.MBEDTLS_GCM_ENCRYPT, plaintext.len, &nonce, nonce.len, aad.ptr, aad.len, plaintext.ptr, ciphertext.ptr, tag_length, tag));
        }

        pub fn decrypt(plaintext: []u8, ciphertext: []const u8, tag: [tag_length]u8, aad: []const u8, nonce: [nonce_length]u8, key: [key_length]u8) errors.AuthenticationError!void {
            var ctx: c.mbedtls_gcm_context = undefined;
            c.mbedtls_gcm_init(&ctx);
            defer c.mbedtls_gcm_free(&ctx);
            checkMbed(c.mbedtls_gcm_setkey(&ctx, c.MBEDTLS_CIPHER_ID_AES, &key, key_length * 8));
            if (c.mbedtls_gcm_auth_decrypt(&ctx, ciphertext.len, &nonce, nonce.len, aad.ptr, aad.len, &tag, tag_length, ciphertext.ptr, plaintext.ptr) != 0) {
                return error.AuthenticationFailed;
            }
        }
    };
}
