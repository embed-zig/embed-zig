pub const sha256_context = extern struct {
    storage: [128]u8 align(8),
};

pub const sha512_context = extern struct {
    storage: [256]u8 align(8),
};

pub const aes_context = extern struct {
    storage: [288]u8 align(8),
};

pub const CertificateInfo = extern struct {
    not_before: i64,
    not_after: i64,
    pk_offset: usize,
    pk_len: usize,
};

pub const RsaHash = enum(c_int) {
    sha256 = 0,
    sha384 = 1,
    sha512 = 2,
};

pub extern const espz_mbedtls_has_chacha20poly1305: bool;
pub extern const espz_mbedtls_has_x25519: bool;
pub extern const espz_mbedtls_has_ed25519: bool;
pub extern const espz_mbedtls_has_hardware_aes: bool;

pub extern fn espz_mbedtls_random_bytes(buf: [*]u8, len: usize) c_int;

pub extern fn espz_mbedtls_sha256_init(ctx: *sha256_context) void;
pub extern fn espz_mbedtls_sha256_clone(dst: *sha256_context, src: *const sha256_context) void;
pub extern fn espz_mbedtls_sha256_update(ctx: *sha256_context, input: [*]const u8, len: usize) void;
pub extern fn espz_mbedtls_sha256_final(ctx: *sha256_context, out: *[32]u8) void;
pub extern fn espz_mbedtls_sha256_hash(input: [*]const u8, len: usize, out: *[32]u8) void;

pub extern fn espz_mbedtls_sha384_init(ctx: *sha512_context) void;
pub extern fn espz_mbedtls_sha384_clone(dst: *sha512_context, src: *const sha512_context) void;
pub extern fn espz_mbedtls_sha384_update(ctx: *sha512_context, input: [*]const u8, len: usize) void;
pub extern fn espz_mbedtls_sha384_final(ctx: *sha512_context, out: *[48]u8) void;
pub extern fn espz_mbedtls_sha384_hash(input: [*]const u8, len: usize, out: *[48]u8) void;

pub extern fn espz_mbedtls_sha512_init(ctx: *sha512_context) void;
pub extern fn espz_mbedtls_sha512_clone(dst: *sha512_context, src: *const sha512_context) void;
pub extern fn espz_mbedtls_sha512_update(ctx: *sha512_context, input: [*]const u8, len: usize) void;
pub extern fn espz_mbedtls_sha512_final(ctx: *sha512_context, out: *[64]u8) void;
pub extern fn espz_mbedtls_sha512_hash(input: [*]const u8, len: usize, out: *[64]u8) void;

pub extern fn espz_mbedtls_aes_init_enc(ctx: *aes_context, key: [*]const u8, key_bits: c_uint) c_int;
pub extern fn espz_mbedtls_aes_init_dec(ctx: *aes_context, key: [*]const u8, key_bits: c_uint) c_int;
pub extern fn espz_mbedtls_aes_encrypt_block(ctx: *const aes_context, input: *const [16]u8, output: *[16]u8) c_int;
pub extern fn espz_mbedtls_aes_decrypt_block(ctx: *const aes_context, input: *const [16]u8, output: *[16]u8) c_int;

pub extern fn espz_mbedtls_aes_gcm_encrypt(
    key_bits: c_uint,
    key: [*]const u8,
    nonce: [*]const u8,
    nonce_len: usize,
    ad: ?[*]const u8,
    ad_len: usize,
    input: ?[*]const u8,
    input_len: usize,
    output: ?[*]u8,
    tag: [*]u8,
    tag_len: usize,
) c_int;

pub extern fn espz_mbedtls_aes_gcm_decrypt(
    key_bits: c_uint,
    key: [*]const u8,
    nonce: [*]const u8,
    nonce_len: usize,
    ad: ?[*]const u8,
    ad_len: usize,
    input: ?[*]const u8,
    input_len: usize,
    output: ?[*]u8,
    tag: [*]const u8,
    tag_len: usize,
) c_int;

pub extern fn espz_mbedtls_chacha20poly1305_encrypt(
    key: [*]const u8,
    nonce: [*]const u8,
    nonce_len: usize,
    ad: ?[*]const u8,
    ad_len: usize,
    input: ?[*]const u8,
    input_len: usize,
    output: ?[*]u8,
    tag: [*]u8,
    tag_len: usize,
) c_int;

pub extern fn espz_mbedtls_chacha20poly1305_decrypt(
    key: [*]const u8,
    nonce: [*]const u8,
    nonce_len: usize,
    ad: ?[*]const u8,
    ad_len: usize,
    input: ?[*]const u8,
    input_len: usize,
    output: ?[*]u8,
    tag: [*]const u8,
    tag_len: usize,
) c_int;

pub extern fn espz_mbedtls_x25519_generate(secret_out: *[32]u8, public_out: *[32]u8) c_int;
pub extern fn espz_mbedtls_x25519_recover_public(secret_key: *const [32]u8, public_out: *[32]u8) c_int;
pub extern fn espz_mbedtls_x25519_scalarmult(secret_key: *const [32]u8, public_key: *const [32]u8, shared_out: *[32]u8) c_int;

pub extern fn espz_mbedtls_certificate_parse(
    der: [*]const u8,
    der_len: usize,
    info_out: *CertificateInfo,
) c_int;

pub extern fn espz_mbedtls_certificate_verify_hostname(
    der: [*]const u8,
    der_len: usize,
    hostname: [*]const u8,
    hostname_len: usize,
) c_int;

pub extern fn espz_mbedtls_certificate_verify(
    subject_der: [*]const u8,
    subject_len: usize,
    issuer_der: [*]const u8,
    issuer_len: usize,
    now_sec: i64,
) c_int;

pub extern fn espz_mbedtls_rsa_verify_pkcs1v15(
    modulus: [*]const u8,
    modulus_len: usize,
    exponent: [*]const u8,
    exponent_len: usize,
    hash_kind: RsaHash,
    digest: [*]const u8,
    digest_len: usize,
    signature: [*]const u8,
    signature_len: usize,
) c_int;

pub extern fn espz_mbedtls_rsa_verify_pss(
    modulus: [*]const u8,
    modulus_len: usize,
    exponent: [*]const u8,
    exponent_len: usize,
    hash_kind: RsaHash,
    digest: [*]const u8,
    digest_len: usize,
    signature: [*]const u8,
    signature_len: usize,
) c_int;
