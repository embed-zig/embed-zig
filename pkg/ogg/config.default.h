#ifndef OGG_CONFIG_H
#define OGG_CONFIG_H

/*
 * Default Ogg configuration shipped by embed-zig.
 *
 * Override the entire header with:
 *   -Dogg=true -Dogg_config_header=path/to/ogg_config.h
 *
 * Integer type selection is handled separately in
 * `pkg/ogg/include/ogg/config_types.h`.
 */

/* CRC verification remains enabled by default. */
/* Define DISABLE_CRC 1 in a custom header to disable it. */

#endif /* OGG_CONFIG_H */
