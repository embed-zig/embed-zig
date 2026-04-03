/*
 * Test:
 *   zig build test-speexdsp -Dspeexdsp=true -Dspeexdsp_config_header=pkg/speexdsp/test_runner/config/fixed_smallft.no_vla.h
 * Latest result from pkg/speexdsp/run_config_matrix.sh on 2026-04-02:
 *   FAIL (SyntheticAecTooWeak)
 *   residual_percent: synthetic=98
 */
#ifndef EMBED_ZIG_SPEEXDSP_TEST_FIXED_SMALLFT_NO_VLA_H
#define EMBED_ZIG_SPEEXDSP_TEST_FIXED_SMALLFT_NO_VLA_H

#define FIXED_POINT
#define USE_SMALLFT
#define EXPORT

#endif
