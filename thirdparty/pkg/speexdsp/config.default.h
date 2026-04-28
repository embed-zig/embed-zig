/*
 * Test:
 *   zig build test -Dspeexdsp_config_header=config.default.h
 * Latest result from pkg/speexdsp/test_matrix/run.sh on 2026-04-13:
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
