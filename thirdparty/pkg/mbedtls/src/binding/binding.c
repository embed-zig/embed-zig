#include "binding.h"

psa_status_t embed_mbedtls_psa_hkdf(
    psa_algorithm_t hash_alg,
    const uint8_t *salt,
    size_t salt_len,
    const uint8_t *ikm,
    size_t ikm_len,
    const uint8_t *info,
    size_t info_len,
    uint8_t *output,
    size_t output_len)
{
    psa_key_derivation_operation_t op = PSA_KEY_DERIVATION_OPERATION_INIT;
    psa_status_t status = psa_key_derivation_setup(&op, PSA_ALG_HKDF(hash_alg));
    if (status != PSA_SUCCESS) {
        return status;
    }

    status = psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_SALT, salt, salt_len);
    if (status == PSA_SUCCESS) {
        status = psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_SECRET, ikm, ikm_len);
    }
    if (status == PSA_SUCCESS) {
        status = psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_INFO, info, info_len);
    }
    if (status == PSA_SUCCESS) {
        status = psa_key_derivation_output_bytes(&op, output, output_len);
    }

    psa_status_t abort_status = psa_key_derivation_abort(&op);
    return status == PSA_SUCCESS ? abort_status : status;
}

static psa_status_t embed_mbedtls_psa_cipher_crypt(
    int encrypt,
    mbedtls_svc_key_id_t key,
    psa_algorithm_t alg,
    const uint8_t *iv,
    size_t iv_len,
    const uint8_t *input,
    size_t input_len,
    uint8_t *output,
    size_t output_size,
    size_t *output_len)
{
    psa_cipher_operation_t op = PSA_CIPHER_OPERATION_INIT;
    psa_status_t status = encrypt
        ? psa_cipher_encrypt_setup(&op, key, alg)
        : psa_cipher_decrypt_setup(&op, key, alg);
    if (status != PSA_SUCCESS) {
        return status;
    }

    status = psa_cipher_set_iv(&op, iv, iv_len);
    size_t update_len = 0;
    size_t finish_len = 0;
    if (status == PSA_SUCCESS) {
        status = psa_cipher_update(&op, input, input_len, output, output_size, &update_len);
    }
    if (status == PSA_SUCCESS) {
        status = psa_cipher_finish(&op, output + update_len, output_size - update_len, &finish_len);
    }
    if (status == PSA_SUCCESS) {
        *output_len = update_len + finish_len;
    }

    psa_status_t abort_status = psa_cipher_abort(&op);
    return status == PSA_SUCCESS ? abort_status : status;
}

psa_status_t embed_mbedtls_psa_cipher_encrypt(
    mbedtls_svc_key_id_t key,
    psa_algorithm_t alg,
    const uint8_t *iv,
    size_t iv_len,
    const uint8_t *input,
    size_t input_len,
    uint8_t *output,
    size_t output_size,
    size_t *output_len)
{
    return embed_mbedtls_psa_cipher_crypt(1, key, alg, iv, iv_len, input, input_len, output, output_size, output_len);
}

psa_status_t embed_mbedtls_psa_cipher_decrypt(
    mbedtls_svc_key_id_t key,
    psa_algorithm_t alg,
    const uint8_t *iv,
    size_t iv_len,
    const uint8_t *input,
    size_t input_len,
    uint8_t *output,
    size_t output_size,
    size_t *output_len)
{
    return embed_mbedtls_psa_cipher_crypt(0, key, alg, iv, iv_len, input, input_len, output, output_size, output_len);
}

void embed_mbedtls_psa_mac_operation_init(psa_mac_operation_t *op)
{
    *op = (psa_mac_operation_t) PSA_MAC_OPERATION_INIT;
}
