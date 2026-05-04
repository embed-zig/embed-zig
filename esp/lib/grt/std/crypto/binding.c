#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS
#define MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS
#endif

#include "mbedtls/private/aes.h"
#include "mbedtls/md.h"
#include "mbedtls/pk.h"
#include "mbedtls/private/pk_private.h"
#include "mbedtls/private_access.h"
#include "mbedtls/private/rsa.h"
#include "mbedtls/private/sha256.h"
#include "mbedtls/private/sha512.h"
#include "mbedtls/x509.h"
#include "mbedtls/x509_crt.h"
#include "psa/crypto.h"

#if defined(PSA_WANT_ALG_CHACHA20_POLY1305)
const bool espz_mbedtls_has_chacha20poly1305 = true;
#else
const bool espz_mbedtls_has_chacha20poly1305 = false;
#endif

#if defined(PSA_WANT_ECC_MONTGOMERY_255) && defined(PSA_WANT_ALG_ECDH)
const bool espz_mbedtls_has_x25519 = true;
#else
const bool espz_mbedtls_has_x25519 = false;
#endif

#if defined(PSA_WANT_ECC_TWISTED_EDWARDS_255) && defined(PSA_WANT_ALG_PURE_EDDSA)
const bool espz_mbedtls_has_ed25519 = true;
#else
const bool espz_mbedtls_has_ed25519 = false;
#endif

#if defined(MBEDTLS_AES_ALT)
const bool espz_mbedtls_has_hardware_aes = true;
#else
const bool espz_mbedtls_has_hardware_aes = false;
#endif

typedef enum espz_mbedtls_rsa_hash_kind {
    ESPZ_MBEDTLS_RSA_HASH_SHA256 = 0,
    ESPZ_MBEDTLS_RSA_HASH_SHA384 = 1,
    ESPZ_MBEDTLS_RSA_HASH_SHA512 = 2,
} espz_mbedtls_rsa_hash_kind;

typedef struct espz_mbedtls_certificate_info {
    int64_t not_before;
    int64_t not_after;
    size_t pk_offset;
    size_t pk_len;
} espz_mbedtls_certificate_info;

typedef struct __attribute__((aligned(8))) espz_mbedtls_sha256_context {
    unsigned char storage[128];
} espz_mbedtls_sha256_context;

typedef struct __attribute__((aligned(8))) espz_mbedtls_sha512_context {
    unsigned char storage[256];
} espz_mbedtls_sha512_context;

typedef struct __attribute__((aligned(8))) espz_mbedtls_aes_context {
    unsigned char storage[288];
} espz_mbedtls_aes_context;

_Static_assert(
    sizeof(mbedtls_sha256_context) <= sizeof(((espz_mbedtls_sha256_context *) 0)->storage),
    "espz_mbedtls_sha256_context is too small for mbedtls_sha256_context"
);
_Static_assert(
    _Alignof(mbedtls_sha256_context) <= _Alignof(espz_mbedtls_sha256_context),
    "espz_mbedtls_sha256_context alignment is too small for mbedtls_sha256_context"
);
_Static_assert(
    sizeof(mbedtls_sha512_context) <= sizeof(((espz_mbedtls_sha512_context *) 0)->storage),
    "espz_mbedtls_sha512_context is too small for mbedtls_sha512_context"
);
_Static_assert(
    _Alignof(mbedtls_sha512_context) <= _Alignof(espz_mbedtls_sha512_context),
    "espz_mbedtls_sha512_context alignment is too small for mbedtls_sha512_context"
);
_Static_assert(
    sizeof(mbedtls_aes_context) <= sizeof(((espz_mbedtls_aes_context *) 0)->storage),
    "espz_mbedtls_aes_context is too small for mbedtls_aes_context"
);
_Static_assert(
    _Alignof(mbedtls_aes_context) <= _Alignof(espz_mbedtls_aes_context),
    "espz_mbedtls_aes_context alignment is too small for mbedtls_aes_context"
);

static mbedtls_sha256_context *espz_sha256_ctx(espz_mbedtls_sha256_context *ctx) {
    return (mbedtls_sha256_context *) ctx->storage;
}

static const mbedtls_sha256_context *espz_sha256_ctx_const(const espz_mbedtls_sha256_context *ctx) {
    return (const mbedtls_sha256_context *) ctx->storage;
}

static mbedtls_sha512_context *espz_sha512_ctx(espz_mbedtls_sha512_context *ctx) {
    return (mbedtls_sha512_context *) ctx->storage;
}

static const mbedtls_sha512_context *espz_sha512_ctx_const(const espz_mbedtls_sha512_context *ctx) {
    return (const mbedtls_sha512_context *) ctx->storage;
}

static mbedtls_aes_context *espz_aes_ctx(espz_mbedtls_aes_context *ctx) {
    return (mbedtls_aes_context *) ctx->storage;
}

static const mbedtls_aes_context *espz_aes_ctx_const(const espz_mbedtls_aes_context *ctx) {
    return (const mbedtls_aes_context *) ctx->storage;
}

static int espz_psa_init(void) {
    static bool initialized = false;
    if (initialized) {
        return PSA_SUCCESS;
    }
    psa_status_t status = psa_crypto_init();
    if (status == PSA_SUCCESS) {
        initialized = true;
    }
    return (int) status;
}

static int import_psa_symmetric_key(
    mbedtls_svc_key_id_t *key_id,
    psa_key_type_t key_type,
    size_t bits,
    psa_algorithm_t alg,
    psa_key_usage_t usage,
    const unsigned char *key,
    size_t key_len
) {
    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, key_type);
    psa_set_key_bits(&attrs, bits);
    psa_set_key_algorithm(&attrs, alg);
    psa_set_key_usage_flags(&attrs, usage);
    return (int) psa_import_key(&attrs, key, key_len, key_id);
}

static int import_psa_x25519_key(
    mbedtls_svc_key_id_t *key_id,
    psa_key_usage_t usage,
    const unsigned char *secret_key,
    size_t secret_key_len
) {
    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attrs, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_MONTGOMERY));
    psa_set_key_bits(&attrs, 255);
    psa_set_key_algorithm(&attrs, PSA_ALG_ECDH);
    psa_set_key_usage_flags(&attrs, usage);
    return (int) psa_import_key(&attrs, secret_key, secret_key_len, key_id);
}

static int64_t days_from_civil(int64_t year, int64_t month, int64_t day) {
    year -= month <= 2;
    const int64_t era = (year >= 0 ? year : year - 399) / 400;
    const int64_t yoe = year - era * 400;
    const int64_t doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
    const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

static int64_t x509_time_to_unix(const mbedtls_x509_time *time) {
    const int64_t days = days_from_civil(time->year, time->mon, time->day);
    return (((days * 24) + time->hour) * 60 + time->min) * 60 + time->sec;
}

static mbedtls_md_type_t hash_kind_to_md(espz_mbedtls_rsa_hash_kind hash_kind) {
    switch (hash_kind) {
        case ESPZ_MBEDTLS_RSA_HASH_SHA256:
            return MBEDTLS_MD_SHA256;
        case ESPZ_MBEDTLS_RSA_HASH_SHA384:
            return MBEDTLS_MD_SHA384;
        case ESPZ_MBEDTLS_RSA_HASH_SHA512:
            return MBEDTLS_MD_SHA512;
        default:
            return MBEDTLS_MD_NONE;
    }
}

int espz_mbedtls_random_bytes(unsigned char *buf, size_t len) {
    if (len == 0) {
        return PSA_SUCCESS;
    }
    const int init_rc = espz_psa_init();
    if (init_rc != PSA_SUCCESS) {
        memset(buf, 0, len);
        return init_rc;
    }
    const psa_status_t status = psa_generate_random(buf, len);
    if (status != PSA_SUCCESS) {
        memset(buf, 0, len);
        return (int) status;
    }
    return PSA_SUCCESS;
}

static int aead_encrypt(
    psa_key_type_t key_type,
    size_t bits,
    psa_algorithm_t alg,
    const unsigned char *key,
    size_t key_len,
    const unsigned char *nonce,
    size_t nonce_len,
    const unsigned char *ad,
    size_t ad_len,
    const unsigned char *input,
    size_t input_len,
    unsigned char *output,
    unsigned char *tag,
    size_t tag_len
) {
    int rc = espz_psa_init();
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    mbedtls_svc_key_id_t key_id = 0;
    rc = import_psa_symmetric_key(&key_id, key_type, bits, alg, PSA_KEY_USAGE_ENCRYPT, key, key_len);
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    unsigned char *combined = NULL;
    size_t combined_len = input_len + tag_len;
    size_t written = 0;

    if (combined_len > 0) {
        combined = calloc(1, combined_len);
        if (combined == NULL) {
            psa_destroy_key(key_id);
            return PSA_ERROR_INSUFFICIENT_MEMORY;
        }
    }

    const psa_status_t status = psa_aead_encrypt(
        key_id,
        alg,
        nonce,
        nonce_len,
        ad,
        ad_len,
        input,
        input_len,
        combined,
        combined_len,
        &written
    );

    if (status == PSA_SUCCESS) {
        if (written != combined_len) {
            rc = PSA_ERROR_GENERIC_ERROR;
        } else {
            if (input_len > 0) {
                memcpy(output, combined, input_len);
            }
            if (tag_len > 0) {
                memcpy(tag, combined + input_len, tag_len);
            }
            rc = PSA_SUCCESS;
        }
    } else {
        rc = (int) status;
    }

    free(combined);
    psa_destroy_key(key_id);
    return rc;
}

static int aead_decrypt(
    psa_key_type_t key_type,
    size_t bits,
    psa_algorithm_t alg,
    const unsigned char *key,
    size_t key_len,
    const unsigned char *nonce,
    size_t nonce_len,
    const unsigned char *ad,
    size_t ad_len,
    const unsigned char *input,
    size_t input_len,
    unsigned char *output,
    const unsigned char *tag,
    size_t tag_len
) {
    int rc = espz_psa_init();
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    mbedtls_svc_key_id_t key_id = 0;
    rc = import_psa_symmetric_key(&key_id, key_type, bits, alg, PSA_KEY_USAGE_DECRYPT, key, key_len);
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    unsigned char *combined = NULL;
    size_t combined_len = input_len + tag_len;
    size_t written = 0;

    if (combined_len > 0) {
        combined = calloc(1, combined_len);
        if (combined == NULL) {
            psa_destroy_key(key_id);
            return PSA_ERROR_INSUFFICIENT_MEMORY;
        }
    }

    if (input_len > 0) {
        memcpy(combined, input, input_len);
    }
    if (tag_len > 0) {
        memcpy(combined + input_len, tag, tag_len);
    }

    const psa_status_t status = psa_aead_decrypt(
        key_id,
        alg,
        nonce,
        nonce_len,
        ad,
        ad_len,
        combined,
        combined_len,
        output,
        input_len,
        &written
    );

    if (status == PSA_SUCCESS) {
        rc = written == input_len ? PSA_SUCCESS : PSA_ERROR_GENERIC_ERROR;
    } else {
        rc = (int) status;
    }

    free(combined);
    psa_destroy_key(key_id);
    return rc;
}

static int verify_cert_signature(mbedtls_x509_crt *subject, mbedtls_x509_crt *issuer) {
    if (subject->issuer_raw.len != issuer->subject_raw.len ||
        memcmp(subject->issuer_raw.p, issuer->subject_raw.p, subject->issuer_raw.len) != 0) {
        return MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
    }

    const mbedtls_md_info_t *md_info = mbedtls_md_info_from_type(subject->MBEDTLS_PRIVATE(sig_md));
    if (md_info == NULL) {
        return MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
    }

    unsigned char hash[64];
    const size_t hash_len = mbedtls_md_get_size(md_info);
    if (hash_len > sizeof(hash)) {
        return MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
    }
    if (mbedtls_md(md_info, subject->tbs.p, subject->tbs.len, hash) != 0) {
        return MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
    }
    if (!mbedtls_pk_can_do(&issuer->pk, subject->MBEDTLS_PRIVATE(sig_pk))) {
        return MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
    }
    return mbedtls_pk_verify_ext(
        subject->MBEDTLS_PRIVATE(sig_pk),
        &issuer->pk,
        subject->MBEDTLS_PRIVATE(sig_md),
        hash,
        hash_len,
        subject->MBEDTLS_PRIVATE(sig).p,
        subject->MBEDTLS_PRIVATE(sig).len
    );
}

static int rsa_verify_common(
    const unsigned char *modulus,
    size_t modulus_len,
    const unsigned char *exponent,
    size_t exponent_len,
    espz_mbedtls_rsa_hash_kind hash_kind,
    const unsigned char *digest,
    size_t digest_len,
    const unsigned char *signature,
    size_t signature_len,
    bool use_pss
) {
    mbedtls_pk_context pk;
    mbedtls_rsa_context *rsa = NULL;
    mbedtls_pk_init(&pk);

    int rc = mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA));
    if (rc != 0) {
        mbedtls_pk_free(&pk);
        return rc;
    }

    rsa = mbedtls_pk_rsa(pk);
    rc = mbedtls_rsa_import_raw(rsa, modulus, modulus_len, NULL, 0, NULL, 0, NULL, 0, exponent, exponent_len);
    if (rc != 0) {
        mbedtls_pk_free(&pk);
        return rc;
    }

    rc = mbedtls_rsa_complete(rsa);
    if (rc != 0) {
        mbedtls_pk_free(&pk);
        return rc;
    }

    rc = mbedtls_rsa_check_pubkey(rsa);
    if (rc != 0) {
        mbedtls_pk_free(&pk);
        return rc;
    }

    const mbedtls_md_type_t md_type = hash_kind_to_md(hash_kind);
    if (md_type == MBEDTLS_MD_NONE) {
        mbedtls_pk_free(&pk);
        return MBEDTLS_ERR_RSA_BAD_INPUT_DATA;
    }

    if (use_pss) {
        rc = mbedtls_pk_verify_ext(
            MBEDTLS_PK_SIGALG_RSA_PSS,
            &pk,
            md_type,
            digest,
            digest_len,
            signature,
            signature_len
        );
    } else {
        rc = mbedtls_pk_verify_ext(
            MBEDTLS_PK_SIGALG_RSA_PKCS1V15,
            &pk,
            md_type,
            digest,
            digest_len,
            signature,
            signature_len
        );
    }

    mbedtls_pk_free(&pk);
    return rc;
}

void espz_mbedtls_sha256_init(espz_mbedtls_sha256_context *ctx) {
    memset(ctx->storage, 0, sizeof(ctx->storage));
    mbedtls_sha256_init(espz_sha256_ctx(ctx));
    (void) mbedtls_sha256_starts(espz_sha256_ctx(ctx), 0);
}

void espz_mbedtls_sha256_clone(espz_mbedtls_sha256_context *dst, const espz_mbedtls_sha256_context *src) {
    memset(dst->storage, 0, sizeof(dst->storage));
    mbedtls_sha256_init(espz_sha256_ctx(dst));
    mbedtls_sha256_clone(espz_sha256_ctx(dst), espz_sha256_ctx_const(src));
}

void espz_mbedtls_sha256_update(espz_mbedtls_sha256_context *ctx, const unsigned char *input, size_t len) {
    (void) mbedtls_sha256_update(espz_sha256_ctx(ctx), input, len);
}

void espz_mbedtls_sha256_final(espz_mbedtls_sha256_context *ctx, unsigned char out[32]) {
    (void) mbedtls_sha256_finish(espz_sha256_ctx(ctx), out);
}

void espz_mbedtls_sha256_hash(const unsigned char *input, size_t len, unsigned char out[32]) {
    (void) mbedtls_sha256(input, len, out, 0);
}

void espz_mbedtls_sha384_init(espz_mbedtls_sha512_context *ctx) {
    memset(ctx->storage, 0, sizeof(ctx->storage));
    mbedtls_sha512_init(espz_sha512_ctx(ctx));
    (void) mbedtls_sha512_starts(espz_sha512_ctx(ctx), 1);
}

void espz_mbedtls_sha384_clone(espz_mbedtls_sha512_context *dst, const espz_mbedtls_sha512_context *src) {
    memset(dst->storage, 0, sizeof(dst->storage));
    mbedtls_sha512_init(espz_sha512_ctx(dst));
    mbedtls_sha512_clone(espz_sha512_ctx(dst), espz_sha512_ctx_const(src));
}

void espz_mbedtls_sha384_update(espz_mbedtls_sha512_context *ctx, const unsigned char *input, size_t len) {
    (void) mbedtls_sha512_update(espz_sha512_ctx(ctx), input, len);
}

void espz_mbedtls_sha384_final(espz_mbedtls_sha512_context *ctx, unsigned char out[48]) {
    unsigned char full[64];
    (void) mbedtls_sha512_finish(espz_sha512_ctx(ctx), full);
    memcpy(out, full, 48);
}

void espz_mbedtls_sha384_hash(const unsigned char *input, size_t len, unsigned char out[48]) {
    unsigned char full[64];
    (void) mbedtls_sha512(input, len, full, 1);
    memcpy(out, full, 48);
}

void espz_mbedtls_sha512_init(espz_mbedtls_sha512_context *ctx) {
    memset(ctx->storage, 0, sizeof(ctx->storage));
    mbedtls_sha512_init(espz_sha512_ctx(ctx));
    (void) mbedtls_sha512_starts(espz_sha512_ctx(ctx), 0);
}

void espz_mbedtls_sha512_clone(espz_mbedtls_sha512_context *dst, const espz_mbedtls_sha512_context *src) {
    memset(dst->storage, 0, sizeof(dst->storage));
    mbedtls_sha512_init(espz_sha512_ctx(dst));
    mbedtls_sha512_clone(espz_sha512_ctx(dst), espz_sha512_ctx_const(src));
}

void espz_mbedtls_sha512_update(espz_mbedtls_sha512_context *ctx, const unsigned char *input, size_t len) {
    (void) mbedtls_sha512_update(espz_sha512_ctx(ctx), input, len);
}

void espz_mbedtls_sha512_final(espz_mbedtls_sha512_context *ctx, unsigned char out[64]) {
    (void) mbedtls_sha512_finish(espz_sha512_ctx(ctx), out);
}

void espz_mbedtls_sha512_hash(const unsigned char *input, size_t len, unsigned char out[64]) {
    (void) mbedtls_sha512(input, len, out, 0);
}

int espz_mbedtls_aes_init_enc(espz_mbedtls_aes_context *ctx, const unsigned char *key, unsigned int key_bits) {
    memset(ctx->storage, 0, sizeof(ctx->storage));
    mbedtls_aes_init(espz_aes_ctx(ctx));
    return mbedtls_aes_setkey_enc(espz_aes_ctx(ctx), key, key_bits);
}

int espz_mbedtls_aes_init_dec(espz_mbedtls_aes_context *ctx, const unsigned char *key, unsigned int key_bits) {
    memset(ctx->storage, 0, sizeof(ctx->storage));
    mbedtls_aes_init(espz_aes_ctx(ctx));
    return mbedtls_aes_setkey_dec(espz_aes_ctx(ctx), key, key_bits);
}

int espz_mbedtls_aes_encrypt_block(const espz_mbedtls_aes_context *ctx, const unsigned char input[16], unsigned char output[16]) {
    return mbedtls_aes_crypt_ecb((mbedtls_aes_context *) espz_aes_ctx_const(ctx), MBEDTLS_AES_ENCRYPT, input, output);
}

int espz_mbedtls_aes_decrypt_block(const espz_mbedtls_aes_context *ctx, const unsigned char input[16], unsigned char output[16]) {
    return mbedtls_aes_crypt_ecb((mbedtls_aes_context *) espz_aes_ctx_const(ctx), MBEDTLS_AES_DECRYPT, input, output);
}

int espz_mbedtls_aes_gcm_encrypt(
    unsigned int key_bits,
    const unsigned char *key,
    const unsigned char *nonce,
    size_t nonce_len,
    const unsigned char *ad,
    size_t ad_len,
    const unsigned char *input,
    size_t input_len,
    unsigned char *output,
    unsigned char *tag,
    size_t tag_len
) {
    return aead_encrypt(
        PSA_KEY_TYPE_AES,
        key_bits,
        PSA_ALG_GCM,
        key,
        key_bits / 8,
        nonce,
        nonce_len,
        ad,
        ad_len,
        input,
        input_len,
        output,
        tag,
        tag_len
    );
}

int espz_mbedtls_aes_gcm_decrypt(
    unsigned int key_bits,
    const unsigned char *key,
    const unsigned char *nonce,
    size_t nonce_len,
    const unsigned char *ad,
    size_t ad_len,
    const unsigned char *input,
    size_t input_len,
    unsigned char *output,
    const unsigned char *tag,
    size_t tag_len
) {
    return aead_decrypt(
        PSA_KEY_TYPE_AES,
        key_bits,
        PSA_ALG_GCM,
        key,
        key_bits / 8,
        nonce,
        nonce_len,
        ad,
        ad_len,
        input,
        input_len,
        output,
        tag,
        tag_len
    );
}

int espz_mbedtls_chacha20poly1305_encrypt(
    const unsigned char *key,
    const unsigned char *nonce,
    size_t nonce_len,
    const unsigned char *ad,
    size_t ad_len,
    const unsigned char *input,
    size_t input_len,
    unsigned char *output,
    unsigned char *tag,
    size_t tag_len
) {
    return aead_encrypt(
        PSA_KEY_TYPE_CHACHA20,
        256,
        PSA_ALG_CHACHA20_POLY1305,
        key,
        32,
        nonce,
        nonce_len,
        ad,
        ad_len,
        input,
        input_len,
        output,
        tag,
        tag_len
    );
}

int espz_mbedtls_chacha20poly1305_decrypt(
    const unsigned char *key,
    const unsigned char *nonce,
    size_t nonce_len,
    const unsigned char *ad,
    size_t ad_len,
    const unsigned char *input,
    size_t input_len,
    unsigned char *output,
    const unsigned char *tag,
    size_t tag_len
) {
    return aead_decrypt(
        PSA_KEY_TYPE_CHACHA20,
        256,
        PSA_ALG_CHACHA20_POLY1305,
        key,
        32,
        nonce,
        nonce_len,
        ad,
        ad_len,
        input,
        input_len,
        output,
        tag,
        tag_len
    );
}

int espz_mbedtls_x25519_generate(unsigned char secret_out[32], unsigned char public_out[32]) {
    int rc = espz_psa_init();
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    psa_key_attributes_t attrs = PSA_KEY_ATTRIBUTES_INIT;
    mbedtls_svc_key_id_t key_id = 0;
    size_t written = 0;

    psa_set_key_type(&attrs, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_MONTGOMERY));
    psa_set_key_bits(&attrs, 255);
    psa_set_key_algorithm(&attrs, PSA_ALG_ECDH);
    psa_set_key_usage_flags(&attrs, PSA_KEY_USAGE_DERIVE | PSA_KEY_USAGE_EXPORT);

    psa_status_t status = psa_generate_key(&attrs, &key_id);
    if (status != PSA_SUCCESS) {
        return (int) status;
    }

    status = psa_export_key(key_id, secret_out, 32, &written);
    if (status == PSA_SUCCESS && written != 32) {
        status = PSA_ERROR_GENERIC_ERROR;
    }
    if (status == PSA_SUCCESS) {
        status = psa_export_public_key(key_id, public_out, 32, &written);
        if (status == PSA_SUCCESS && written != 32) {
            status = PSA_ERROR_GENERIC_ERROR;
        }
    }

    psa_destroy_key(key_id);
    return (int) status;
}

int espz_mbedtls_x25519_recover_public(const unsigned char secret_key[32], unsigned char public_out[32]) {
    int rc = espz_psa_init();
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    mbedtls_svc_key_id_t key_id = 0;
    size_t written = 0;
    rc = import_psa_x25519_key(&key_id, PSA_KEY_USAGE_DERIVE | PSA_KEY_USAGE_EXPORT, secret_key, 32);
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    const psa_status_t status = psa_export_public_key(key_id, public_out, 32, &written);
    psa_destroy_key(key_id);
    if (status != PSA_SUCCESS) {
        return (int) status;
    }
    return written == 32 ? PSA_SUCCESS : PSA_ERROR_GENERIC_ERROR;
}

int espz_mbedtls_x25519_scalarmult(
    const unsigned char secret_key[32],
    const unsigned char public_key[32],
    unsigned char shared_out[32]
) {
    int rc = espz_psa_init();
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    mbedtls_svc_key_id_t key_id = 0;
    size_t written = 0;
    rc = import_psa_x25519_key(&key_id, PSA_KEY_USAGE_DERIVE, secret_key, 32);
    if (rc != PSA_SUCCESS) {
        return rc;
    }

    const psa_status_t status = psa_raw_key_agreement(
        PSA_ALG_ECDH,
        key_id,
        public_key,
        32,
        shared_out,
        32,
        &written
    );

    psa_destroy_key(key_id);
    if (status != PSA_SUCCESS) {
        return (int) status;
    }
    return written == 32 ? PSA_SUCCESS : PSA_ERROR_GENERIC_ERROR;
}

int espz_mbedtls_certificate_parse(
    const unsigned char *der,
    size_t der_len,
    espz_mbedtls_certificate_info *info_out
) {
    mbedtls_x509_crt crt;
    mbedtls_x509_crt_init(&crt);
    const int rc = mbedtls_x509_crt_parse_der(&crt, der, der_len);
    if (rc == 0) {
        info_out->not_before = x509_time_to_unix(&crt.valid_from);
        info_out->not_after = x509_time_to_unix(&crt.valid_to);
        info_out->pk_offset = (size_t) (crt.pk_raw.p - crt.raw.p);
        info_out->pk_len = crt.pk_raw.len;
    }
    mbedtls_x509_crt_free(&crt);
    return rc;
}

int espz_mbedtls_certificate_verify_hostname(
    const unsigned char *der,
    size_t der_len,
    const unsigned char *hostname,
    size_t hostname_len
) {
    mbedtls_x509_crt crt;
    mbedtls_x509_crt_init(&crt);
    int rc = mbedtls_x509_crt_parse_der(&crt, der, der_len);
    if (rc != 0) {
        mbedtls_x509_crt_free(&crt);
        return rc;
    }

    rc = MBEDTLS_ERR_X509_BAD_INPUT_DATA;
    for (mbedtls_x509_sequence *cur = &crt.subject_alt_names; cur != NULL; cur = cur->next) {
        if (cur->buf.p == NULL || cur->buf.len == 0) {
            continue;
        }
        mbedtls_x509_subject_alternative_name san;
        memset(&san, 0, sizeof(san));
        const int san_rc = mbedtls_x509_parse_subject_alt_name(&cur->buf, &san);
        if (san_rc == 0) {
            if (san.type == MBEDTLS_X509_SAN_DNS_NAME &&
                san.san.unstructured_name.len == hostname_len &&
                memcmp(san.san.unstructured_name.p, hostname, hostname_len) == 0) {
                rc = 0;
                mbedtls_x509_free_subject_alt_name(&san);
                break;
            }
            mbedtls_x509_free_subject_alt_name(&san);
        }
    }

    mbedtls_x509_crt_free(&crt);
    return rc;
}

int espz_mbedtls_certificate_verify(
    const unsigned char *subject_der,
    size_t subject_len,
    const unsigned char *issuer_der,
    size_t issuer_len,
    int64_t now_sec
) {
    mbedtls_x509_crt subject;
    mbedtls_x509_crt issuer;
    mbedtls_x509_crt_init(&subject);
    mbedtls_x509_crt_init(&issuer);

    int rc = mbedtls_x509_crt_parse_der(&subject, subject_der, subject_len);
    if (rc != 0) {
        goto done;
    }
    rc = mbedtls_x509_crt_parse_der(&issuer, issuer_der, issuer_len);
    if (rc != 0) {
        goto done;
    }

    const int64_t not_before = x509_time_to_unix(&subject.valid_from);
    const int64_t not_after = x509_time_to_unix(&subject.valid_to);
    if (now_sec < not_before || now_sec > not_after) {
        rc = MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
        goto done;
    }

    rc = verify_cert_signature(&subject, &issuer);

done:
    mbedtls_x509_crt_free(&issuer);
    mbedtls_x509_crt_free(&subject);
    return rc;
}

int espz_mbedtls_rsa_verify_pkcs1v15(
    const unsigned char *modulus,
    size_t modulus_len,
    const unsigned char *exponent,
    size_t exponent_len,
    espz_mbedtls_rsa_hash_kind hash_kind,
    const unsigned char *digest,
    size_t digest_len,
    const unsigned char *signature,
    size_t signature_len
) {
    return rsa_verify_common(
        modulus,
        modulus_len,
        exponent,
        exponent_len,
        hash_kind,
        digest,
        digest_len,
        signature,
        signature_len,
        false
    );
}

int espz_mbedtls_rsa_verify_pss(
    const unsigned char *modulus,
    size_t modulus_len,
    const unsigned char *exponent,
    size_t exponent_len,
    espz_mbedtls_rsa_hash_kind hash_kind,
    const unsigned char *digest,
    size_t digest_len,
    const unsigned char *signature,
    size_t signature_len
) {
    return rsa_verify_common(
        modulus,
        modulus_len,
        exponent,
        exponent_len,
        hash_kind,
        digest,
        digest_len,
        signature,
        signature_len,
        true
    );
}
