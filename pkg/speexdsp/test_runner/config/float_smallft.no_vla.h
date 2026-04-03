/*
 * Test:
 *   zig build test-speexdsp -Dspeexdsp=true -Dspeexdsp_config_header=pkg/speexdsp/test_runner/config/float_smallft.no_vla.h
 * Latest result from pkg/speexdsp/run_config_matrix.sh on 2026-04-02:
 *   PASS
 *   residual_percent: synthetic=1 split=1 reset_fresh=1 reset_dirty=1
 */
#ifndef EMBED_ZIG_SPEEXDSP_TEST_FLOAT_SMALLFT_NO_VLA_H
#define EMBED_ZIG_SPEEXDSP_TEST_FLOAT_SMALLFT_NO_VLA_H

#define FLOATING_POINT
#define USE_SMALLFT
#define EXPORT

#endif
