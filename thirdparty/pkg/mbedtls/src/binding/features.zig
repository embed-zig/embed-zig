const c = @import("c.zig").c;

fn has(comptime name: []const u8) bool {
    return @hasDecl(c, name);
}

pub const versions = struct {
    pub const mbedtls_number = if (has("MBEDTLS_VERSION_NUMBER")) c.MBEDTLS_VERSION_NUMBER else 0;
    pub const tf_psa_crypto_number = if (has("TF_PSA_CRYPTO_VERSION_NUMBER")) c.TF_PSA_CRYPTO_VERSION_NUMBER else 0;
};

pub const psa = struct {
    pub const crypto = has("PSA_CRYPTO_H");
    pub const sha256 = has("PSA_WANT_ALG_SHA_256");
    pub const sha384 = has("PSA_WANT_ALG_SHA_384");
    pub const sha512 = has("PSA_WANT_ALG_SHA_512");
    pub const sha3 = has("PSA_WANT_ALG_SHA3_256");
    pub const hmac = has("PSA_WANT_ALG_HMAC");
    pub const cmac = has("PSA_WANT_ALG_CMAC");
    pub const hkdf = has("PSA_WANT_ALG_HKDF");
    pub const pbkdf2_hmac = has("PSA_WANT_ALG_PBKDF2_HMAC");
    pub const aes = has("PSA_WANT_KEY_TYPE_AES");
    pub const ctr = has("PSA_WANT_ALG_CTR");
    pub const cbc_no_padding = has("PSA_WANT_ALG_CBC_NO_PADDING");
    pub const gcm = has("PSA_WANT_ALG_GCM");
    pub const nist_kw = has("MBEDTLS_NIST_KW_C");
    pub const chacha20_poly1305 = has("PSA_WANT_ALG_CHACHA20_POLY1305");
    pub const ecdh = has("PSA_WANT_ALG_ECDH");
    pub const ecdsa = has("PSA_WANT_ALG_ECDSA");
    pub const p256 = has("PSA_WANT_ECC_SECP_R1_256");
    pub const p384 = has("PSA_WANT_ECC_SECP_R1_384");
    pub const x25519 = has("PSA_WANT_ECC_MONTGOMERY_255");
    pub const eddsa_algorithm_ids = has("PSA_ALG_PURE_EDDSA") and has("PSA_ALG_ED25519PH");
    pub const ed25519 = false;
};

pub const tls = struct {
    pub const ssl = has("MBEDTLS_SSL_TLS_C");
    pub const tls12 = has("MBEDTLS_SSL_PROTO_TLS1_2");
    pub const tls13 = has("MBEDTLS_SSL_PROTO_TLS1_3");
};

pub const x509 = struct {
    pub const crt = has("MBEDTLS_X509_CRT_PARSE_C");
    pub const crl = has("MBEDTLS_X509_CRL_PARSE_C");
    pub const csr = has("MBEDTLS_X509_CSR_PARSE_C");
};
