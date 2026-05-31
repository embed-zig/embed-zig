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
void *wv_display_native_panel_io(void);

int wv_audio_set_pa(bool enabled);

#ifdef __cplusplus
}
#endif
