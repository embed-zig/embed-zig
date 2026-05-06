#ifndef OPUS_CONFIG_H
#define OPUS_CONFIG_H

/*
 * Default Opus configuration shipped by embed-zig.
 *
 * Override the entire header with:
 *   -Dopus=true -Dopus_config_header=path/to/opus_config.h
 */

/* Required for the fixed-point libopus build used by this package. */
#include <stddef.h>

#define FIXED_POINT 1
#define OPUS_BUILD 1

/*
 * Keep CELT temporary decode buffers off small embedded task stacks.
 * This mode uses the package-provided opus_alloc_scratch() implementation.
 */
#define NONTHREADSAFE_PSEUDOSTACK 1
#define OVERRIDE_OPUS_ALLOC_SCRATCH 1

void *opus_alloc_scratch(size_t size);

/*
 * Optional knobs such as HAVE_LRINT, HAVE_LRINTF, DISABLE_FLOAT_API,
 * CUSTOM_MODES, and ENABLE_HARDENING remain undefined by default.
 * Define them in a custom header when needed.
 */

#endif /* OPUS_CONFIG_H */
