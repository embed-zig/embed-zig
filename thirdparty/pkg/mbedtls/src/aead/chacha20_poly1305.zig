const shared = @import("../shared.zig");

const c = shared.c;
const errors = shared.errors;
const checkMbed = shared.checkMbed;

pub const ChaCha20Poly1305 = struct {
    pub const tag_length = 16;
    pub const nonce_length = 12;
    pub const key_length = 32;

    pub fn encrypt(ciphertext: []u8, tag: *[tag_length]u8, plaintext: []const u8, aad: []const u8, nonce: [nonce_length]u8, key: [key_length]u8) void {
        var ctx: c.mbedtls_chachapoly_context = undefined;
        c.mbedtls_chachapoly_init(&ctx);
        defer c.mbedtls_chachapoly_free(&ctx);
        checkMbed(c.mbedtls_chachapoly_setkey(&ctx, &key));
        checkMbed(c.mbedtls_chachapoly_encrypt_and_tag(&ctx, plaintext.len, &nonce, aad.ptr, aad.len, plaintext.ptr, ciphertext.ptr, tag));
    }

    pub fn decrypt(plaintext: []u8, ciphertext: []const u8, tag: [tag_length]u8, aad: []const u8, nonce: [nonce_length]u8, key: [key_length]u8) errors.AuthenticationError!void {
        var ctx: c.mbedtls_chachapoly_context = undefined;
        c.mbedtls_chachapoly_init(&ctx);
        defer c.mbedtls_chachapoly_free(&ctx);
        checkMbed(c.mbedtls_chachapoly_setkey(&ctx, &key));
        if (c.mbedtls_chachapoly_auth_decrypt(&ctx, ciphertext.len, &nonce, aad.ptr, aad.len, &tag, ciphertext.ptr, plaintext.ptr) != 0) {
            return error.AuthenticationFailed;
        }
    }
};
