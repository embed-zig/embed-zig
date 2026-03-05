//! AEAD ciphers - ESP32 mbedTLS implementation.
//!
//! AES-128/256-GCM (hardware accelerated on ESP32) and ChaCha20-Poly1305
//! (software) using mbedTLS via C helpers.

extern fn aes_gcm_encrypt(
    key: [*]const u8,
    key_len: usize,
    iv: [*]const u8,
    iv_len: usize,
    aad: ?[*]const u8,
    aad_len: usize,
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
    tag: *[16]u8,
) c_int;

extern fn aes_gcm_decrypt(
    key: [*]const u8,
    key_len: usize,
    iv: [*]const u8,
    iv_len: usize,
    aad: ?[*]const u8,
    aad_len: usize,
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
    tag: *const [16]u8,
) c_int;

extern fn chachapoly_encrypt(
    key: *const [32]u8,
    nonce: *const [12]u8,
    aad: ?[*]const u8,
    aad_len: usize,
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
    tag: *[16]u8,
) c_int;

extern fn chachapoly_decrypt(
    key: *const [32]u8,
    nonce: *const [12]u8,
    aad: ?[*]const u8,
    aad_len: usize,
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
    tag: *const [16]u8,
) c_int;

fn AesGcmImpl(comptime key_len: usize) type {
    return struct {
        pub const key_length = key_len;
        pub const nonce_length = 12;
        pub const tag_length = 16;

        pub fn encryptStatic(
            ciphertext: []u8,
            tag: *[tag_length]u8,
            plaintext: []const u8,
            aad: []const u8,
            nonce: [nonce_length]u8,
            key: [key_length]u8,
        ) void {
            const ret = aes_gcm_encrypt(
                &key,
                key_length,
                &nonce,
                nonce_length,
                if (aad.len > 0) aad.ptr else null,
                aad.len,
                plaintext.ptr,
                plaintext.len,
                ciphertext.ptr,
                tag,
            );
            if (ret != 0) @panic("aes_gcm_encrypt failed");
        }

        pub fn decryptStatic(
            plaintext: []u8,
            ciphertext: []const u8,
            tag: [tag_length]u8,
            aad: []const u8,
            nonce: [nonce_length]u8,
            key: [key_length]u8,
        ) error{AuthenticationFailed}!void {
            const ret = aes_gcm_decrypt(
                &key,
                key_length,
                &nonce,
                nonce_length,
                if (aad.len > 0) aad.ptr else null,
                aad.len,
                ciphertext.ptr,
                ciphertext.len,
                plaintext.ptr,
                &tag,
            );
            if (ret != 0) return error.AuthenticationFailed;
        }
    };
}

pub const Aes128Gcm = AesGcmImpl(16);
pub const Aes256Gcm = AesGcmImpl(32);

pub const ChaCha20Poly1305 = struct {
    pub const key_length = 32;
    pub const nonce_length = 12;
    pub const tag_length = 16;

    pub fn encryptStatic(
        ciphertext: []u8,
        tag: *[tag_length]u8,
        plaintext: []const u8,
        aad: []const u8,
        nonce: [nonce_length]u8,
        key: [key_length]u8,
    ) void {
        const ret = chachapoly_encrypt(
            &key,
            &nonce,
            if (aad.len > 0) aad.ptr else null,
            aad.len,
            plaintext.ptr,
            plaintext.len,
            ciphertext.ptr,
            tag,
        );
        if (ret != 0) @panic("chachapoly_encrypt failed");
    }

    pub fn decryptStatic(
        plaintext: []u8,
        ciphertext: []const u8,
        tag: [tag_length]u8,
        aad: []const u8,
        nonce: [nonce_length]u8,
        key: [key_length]u8,
    ) error{AuthenticationFailed}!void {
        const ret = chachapoly_decrypt(
            &key,
            &nonce,
            if (aad.len > 0) aad.ptr else null,
            aad.len,
            ciphertext.ptr,
            ciphertext.len,
            plaintext.ptr,
            &tag,
        );
        if (ret != 0) return error.AuthenticationFailed;
    }
};
