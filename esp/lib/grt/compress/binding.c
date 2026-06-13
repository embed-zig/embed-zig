#include <stdint.h>
#include <stdlib.h>

#include "miniz.h"

enum {
    ESPZ_COMPRESS_CONTAINER_RAW = 0,
    ESPZ_COMPRESS_CONTAINER_ZLIB = 1,
    ESPZ_COMPRESS_CONTAINER_GZIP = 2,
};

enum {
    ESPZ_COMPRESS_OK = 0,
    ESPZ_COMPRESS_INVALID_DATA = -1,
    ESPZ_COMPRESS_TRUNCATED_INPUT = -2,
    ESPZ_COMPRESS_OUTPUT_TOO_SMALL = -3,
    ESPZ_COMPRESS_UNSUPPORTED = -4,
    ESPZ_COMPRESS_UNEXPECTED = -5,
};

int espz_compress_inflate(
    int container,
    const uint8_t *compressed,
    size_t compressed_len,
    uint8_t *out,
    size_t out_len,
    size_t *written)
{
    if ((compressed == NULL && compressed_len != 0) || out == NULL || written == NULL) {
        return ESPZ_COMPRESS_UNEXPECTED;
    }
    if (container == ESPZ_COMPRESS_CONTAINER_GZIP) {
        return ESPZ_COMPRESS_UNSUPPORTED;
    }
    if (container != ESPZ_COMPRESS_CONTAINER_RAW && container != ESPZ_COMPRESS_CONTAINER_ZLIB) {
        return ESPZ_COMPRESS_UNSUPPORTED;
    }

    tinfl_decompressor *decomp = calloc(1, sizeof(tinfl_decompressor));
    if (decomp == NULL) {
        return ESPZ_COMPRESS_UNEXPECTED;
    }
    tinfl_init(decomp);

    size_t in_pos = 0;
    size_t out_pos = 0;
    const mz_uint32 flags = TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF |
        (container == ESPZ_COMPRESS_CONTAINER_ZLIB ? TINFL_FLAG_PARSE_ZLIB_HEADER : 0);

    while (1) {
        size_t in_bytes = compressed_len - in_pos;
        size_t out_bytes = out_len - out_pos;
        tinfl_status status = tinfl_decompress(
            decomp,
            compressed + in_pos,
            &in_bytes,
            out,
            out + out_pos,
            &out_bytes,
            flags);

        in_pos += in_bytes;
        out_pos += out_bytes;

        if (status == TINFL_STATUS_DONE) {
            *written = out_pos;
            free(decomp);
            return ESPZ_COMPRESS_OK;
        }
        if (status == TINFL_STATUS_HAS_MORE_OUTPUT) {
            free(decomp);
            return ESPZ_COMPRESS_OUTPUT_TOO_SMALL;
        }
        if (status == TINFL_STATUS_NEEDS_MORE_INPUT) {
            free(decomp);
            return ESPZ_COMPRESS_TRUNCATED_INPUT;
        }
        if (status < TINFL_STATUS_DONE) {
            free(decomp);
            return ESPZ_COMPRESS_INVALID_DATA;
        }
        if (in_bytes == 0 && out_bytes == 0) {
            free(decomp);
            return ESPZ_COMPRESS_UNEXPECTED;
        }
    }
}
