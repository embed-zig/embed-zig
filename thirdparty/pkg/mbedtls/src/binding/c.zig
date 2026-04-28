pub const c = @cImport({
    @cInclude("psa/crypto.h");
    @cInclude("psa/crypto_extra.h");
    @cInclude("tf-psa-crypto/build_info.h");
    @cInclude("tf-psa-crypto/version.h");
    @cInclude("mbedtls/build_info.h");
    @cInclude("mbedtls/version.h");
    @cInclude("mbedtls/error.h");
    @cInclude("mbedtls/private/aes.h");
    @cInclude("mbedtls/private/gcm.h");
    @cInclude("mbedtls/private/chachapoly.h");
    @cInclude("mbedtls/private/sha256.h");
    @cInclude("mbedtls/private/sha512.h");
    @cInclude("binding/binding.h");
});
