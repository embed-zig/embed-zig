#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int szp_board_init(void);

int szp_storage_init_nvs(void);
int szp_storage_mount(void);
int szp_storage_info(size_t *total, size_t *used);
int szp_storage_unmount(void);

int szp_audio_init(void);
int szp_audio_set_pa(bool enabled);
int szp_audio_write_i16(const int16_t *pcm, size_t sample_count);
int szp_audio_mic_capture_start(void);
int szp_audio_mic_read_i16(int16_t *mic0, int16_t *mic1, int16_t *ref, size_t sample_capacity, size_t *sample_count);
int szp_audio_mic_capture_stop(void);
int szp_audio_afe_process_i16(
    const int16_t *mic0,
    const int16_t *mic1,
    const int16_t *ref,
    size_t sample_count,
    int16_t *out,
    size_t out_capacity,
    size_t *out_count);

int szp_button_init(void);
bool szp_button_read_raw(void);

int szp_display_native_init(void);
int szp_display_native_set_enabled(bool enabled);
int szp_display_native_set_brightness(uint8_t brightness);
int szp_display_native_draw_rgb565(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t *pixels, size_t len);

#ifdef __cplusplus
}
#endif
