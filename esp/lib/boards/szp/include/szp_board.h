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

int szp_audio_set_pa(bool enabled);

int szp_button_init(void);
bool szp_button_read_raw(void);

int szp_display_native_init(void);
void *szp_display_native_panel_io(void);
int szp_display_native_set_brightness(uint8_t brightness);

#ifdef __cplusplus
}
#endif
