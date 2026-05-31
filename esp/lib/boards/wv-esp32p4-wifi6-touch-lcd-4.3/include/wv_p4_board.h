#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

int wv_p4_board_init(void);
int wv_p4_power_button_init(void);
bool wv_p4_power_button_pressed(void);

int wv_p4_display_native_init(void);
void *wv_p4_display_native_panel_io(void);
int wv_p4_display_native_reset_panel(void);
int wv_p4_display_native_start_panel(void);
int wv_p4_display_native_set_brightness(uint8_t brightness);
int wv_p4_display_native_flush_rgb565(
    uint16_t x,
    uint16_t y,
    uint16_t w,
    uint16_t h,
    const uint16_t *pixels,
    size_t len);

int wv_p4_audio_set_pa(bool enabled);
