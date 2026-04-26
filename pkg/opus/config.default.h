#ifndef OPUS_CONFIG_H
#define OPUS_CONFIG_H

/*
 * Default Opus configuration shipped by embed-zig.
 *
 * Override the entire header with:
 *   -Dopus=true -Dopus_config_header=path/to/opus_config.h
 */

/* Required for the fixed-point libopus build used by this package. */
#define FIXED_POINT 1
#define OPUS_BUILD 1
#define VAR_ARRAYS 1

/*
 * Optional knobs such as HAVE_LRINT, HAVE_LRINTF, DISABLE_FLOAT_API,
 * CUSTOM_MODES, and ENABLE_HARDENING remain undefined by default.
 * Define them in a custom header when needed.
 */

#endif /* OPUS_CONFIG_H */
