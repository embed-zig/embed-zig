/*
 * Test:
 *   zig build test-speexdsp -Dspeexdsp=true -Dspeexdsp_config_header=pkg/speexdsp/test_runner/config/fixed_kiss_fft.no_vla.h
 * Latest result from pkg/speexdsp/run_config_matrix.sh on 2026-04-02:
 *   PASS
 *   residual_percent: synthetic=1 split=1 reset_fresh=1 reset_dirty=1
 */
#ifndef EMBED_ZIG_SPEEXDSP_TEST_FIXED_KISS_FFT_NO_VLA_H
#define EMBED_ZIG_SPEEXDSP_TEST_FIXED_KISS_FFT_NO_VLA_H

#define FIXED_POINT
#define USE_KISS_FFT
#define EXPORT

#endif
