#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SZP_TRACK_TWINKLE = 0,
    SZP_TRACK_HAPPY_BIRTHDAY = 1,
    SZP_TRACK_DOLL_BEAR = 2,
} szp_track_t;

int szp_board_init(void);

int szp_storage_init_nvs(void);
int szp_storage_mount(void);
int szp_storage_info(size_t *total, size_t *used);
int szp_storage_unmount(void);

int szp_audio_init(void);
int szp_audio_set_pa(bool enabled);
int szp_audio_write_i16(const int16_t *pcm, size_t sample_count);
int szp_audio_play_test_tone(uint32_t frequency_hz, uint32_t duration_ms);
int szp_audio_mic_start(void);
int szp_audio_mic_process_frame(void);
int szp_audio_mic_stop(void);

int szp_button_init(void);
bool szp_button_read_raw(void);

int szp_display_native_init(void);
int szp_display_native_draw_rgb565(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t *pixels, size_t len);

#ifdef __cplusplus
}
#endif
