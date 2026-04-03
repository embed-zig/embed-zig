/*
 * Test:
 *   zig build test-speexdsp -Dspeexdsp=true -Dspeexdsp_config_header=pkg/speexdsp/config.default.h
 * Latest result from pkg/speexdsp/run_config_matrix.sh on 2026-04-02:
 *   PASS
 *   residual_percent: synthetic=1 split=1 reset_fresh=1 reset_dirty=1
 */
#ifndef EMBED_ZIG_SPEEXDSP_CONFIG_DEFAULT_H
#define EMBED_ZIG_SPEEXDSP_CONFIG_DEFAULT_H

#define FLOATING_POINT
#define USE_SMALLFT
#define EXPORT
#define VAR_ARRAYS

#endif
