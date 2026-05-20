#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int wv_power_button_init(void);
bool wv_power_button_pressed(void);

int wv_storage_init_nvs(void);

int wv_display_native_init(void);
int wv_display_native_set_enabled(bool enabled);
int wv_display_native_set_brightness(uint8_t brightness);
int wv_display_native_draw_rgb565(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t *pixels, size_t len);

int wv_audio_init(void);
int wv_audio_set_pa(bool enabled);
int wv_audio_write_i16(const int16_t *pcm, size_t sample_count);
int wv_audio_mic_capture_start(void);
int wv_audio_mic_read_i16(int16_t *mic0, size_t sample_capacity, size_t *sample_count);
int wv_audio_mic_capture_stop(void);

#ifdef __cplusplus
}
#endif
