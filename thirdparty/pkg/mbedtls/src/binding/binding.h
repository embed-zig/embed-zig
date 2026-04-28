#ifndef EMBED_MBEDTLS_BINDING_H
#define EMBED_MBEDTLS_BINDING_H

#include <stddef.h>
#include <stdint.h>

#include <psa/crypto.h>

enum {
    EMBED_MBEDTLS_PSA_MAC_OPERATION_SIZE = sizeof(psa_mac_operation_t),
    EMBED_MBEDTLS_PSA_MAC_OPERATION_ALIGN = _Alignof(psa_mac_operation_t),
};

psa_status_t embed_mbedtls_psa_hkdf(
    psa_algorithm_t hash_alg,
    const uint8_t *salt,
    size_t salt_len,
    const uint8_t *ikm,
    size_t ikm_len,
    const uint8_t *info,
    size_t info_len,
    uint8_t *output,
    size_t output_len);

psa_status_t embed_mbedtls_psa_cipher_encrypt(
    mbedtls_svc_key_id_t key,
    psa_algorithm_t alg,
    const uint8_t *iv,
    size_t iv_len,
    const uint8_t *input,
    size_t input_len,
    uint8_t *output,
    size_t output_size,
    size_t *output_len);

psa_status_t embed_mbedtls_psa_cipher_decrypt(
    mbedtls_svc_key_id_t key,
    psa_algorithm_t alg,
    const uint8_t *iv,
    size_t iv_len,
    const uint8_t *input,
    size_t input_len,
    uint8_t *output,
    size_t output_size,
    size_t *output_len);

void embed_mbedtls_psa_mac_operation_init(psa_mac_operation_t *op);

#endif
