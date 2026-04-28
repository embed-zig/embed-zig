const errors = @import("../error.zig");

const c = @import("../c.zig").c;

pub const KeyId = c.mbedtls_svc_key_id_t;
pub const Status = c.psa_status_t;
pub const KeyType = c.psa_key_type_t;
pub const Algorithm = c.psa_algorithm_t;
pub const Usage = c.psa_key_usage_t;

pub const alg = struct {
    pub const sha256 = c.PSA_ALG_SHA_256;
    pub const sha384 = c.PSA_ALG_SHA_384;
    pub const sha512 = c.PSA_ALG_SHA_512;
    pub const sha3_256 = if (@hasDecl(c, "PSA_ALG_SHA3_256")) c.PSA_ALG_SHA3_256 else 0;
    pub const sha3_384 = if (@hasDecl(c, "PSA_ALG_SHA3_384")) c.PSA_ALG_SHA3_384 else 0;
    pub const sha3_512 = if (@hasDecl(c, "PSA_ALG_SHA3_512")) c.PSA_ALG_SHA3_512 else 0;
    pub const ecdh = c.PSA_ALG_ECDH;
    pub const ctr = c.PSA_ALG_CTR;
    pub const cbc_no_padding = c.PSA_ALG_CBC_NO_PADDING;
    pub const gcm = c.PSA_ALG_GCM;
    pub const chacha20_poly1305 = c.PSA_ALG_CHACHA20_POLY1305;
    pub const cmac = c.PSA_ALG_CMAC;

    pub fn hmac(hash_alg: Algorithm) Algorithm {
        return c.PSA_ALG_HMAC(hash_alg);
    }

    pub fn ecdsa(hash_alg: Algorithm) Algorithm {
        return c.PSA_ALG_ECDSA(hash_alg);
    }

    pub fn rsaPkcs1v15Sign(hash_alg: Algorithm) Algorithm {
        return c.PSA_ALG_RSA_PKCS1V15_SIGN(hash_alg);
    }

    pub fn rsaPss(hash_alg: Algorithm) Algorithm {
        return c.PSA_ALG_RSA_PSS(hash_alg);
    }

    pub fn hkdf(hash_alg: Algorithm) Algorithm {
        return c.PSA_ALG_HKDF(hash_alg);
    }

    pub fn pbkdf2Hmac(hash_alg: Algorithm) Algorithm {
        return c.PSA_ALG_PBKDF2_HMAC(hash_alg);
    }
};

pub const key_type = struct {
    pub const raw_data = c.PSA_KEY_TYPE_RAW_DATA;
    pub const aes = c.PSA_KEY_TYPE_AES;
    pub const chacha20 = if (@hasDecl(c, "PSA_KEY_TYPE_CHACHA20")) c.PSA_KEY_TYPE_CHACHA20 else c.PSA_KEY_TYPE_RAW_DATA;
    pub const hmac = c.PSA_KEY_TYPE_HMAC;
    pub const rsaPublicKey = c.PSA_KEY_TYPE_RSA_PUBLIC_KEY;

    pub fn eccKeyPair(family: c.psa_ecc_family_t) KeyType {
        return c.PSA_KEY_TYPE_ECC_KEY_PAIR(family);
    }

    pub fn eccPublicKey(family: c.psa_ecc_family_t) KeyType {
        return c.PSA_KEY_TYPE_ECC_PUBLIC_KEY(family);
    }
};

pub const ecc_family = struct {
    pub const secp_r1 = c.PSA_ECC_FAMILY_SECP_R1;
    pub const montgomery = c.PSA_ECC_FAMILY_MONTGOMERY;
    pub const twisted_edwards = c.PSA_ECC_FAMILY_TWISTED_EDWARDS;
};

pub const usage = struct {
    pub const export_key = c.PSA_KEY_USAGE_EXPORT;
    pub const copy = c.PSA_KEY_USAGE_COPY;
    pub const encrypt = c.PSA_KEY_USAGE_ENCRYPT;
    pub const decrypt = c.PSA_KEY_USAGE_DECRYPT;
    pub const sign_hash = c.PSA_KEY_USAGE_SIGN_HASH;
    pub const verify_hash = c.PSA_KEY_USAGE_VERIFY_HASH;
    pub const sign_message = c.PSA_KEY_USAGE_SIGN_MESSAGE;
    pub const verify_message = c.PSA_KEY_USAGE_VERIFY_MESSAGE;
    pub const derive = c.PSA_KEY_USAGE_DERIVE;
};

pub fn init() errors.Error!void {
    try errors.check(c.psa_crypto_init());
}

pub fn random(out: []u8) errors.Error!void {
    try init();
    try errors.check(c.psa_generate_random(out.ptr, out.len));
}
